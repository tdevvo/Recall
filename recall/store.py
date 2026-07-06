# Core persistence + search for Recall documents.
# Python port of src/store.cpp; shares the same database as the C++ app.
# Rendering happens in QML (TextEdit.MarkdownText) — no HTML generation here.
import sqlite3

from PySide6.QtCore import QObject, QStandardPaths, Signal, Slot

WELCOME_MD = """# Welcome to Recall

Recall is a wiki-like tree of documents.

- Browse documents in the tree on the left.
- Search with the bar at the top.
- Add documents with the button above the tree; right-click a document to add a child or edit it.
- AI agents can also edit documents through the `recall-mcp` server (stdio MCP transport).

Documents may be written in **Markdown** or raw HTML (content starting with `<` is rendered as-is)."""

CODING_EXAMPLE_MD = """# Coding Example

This document shows the rich text features Recall renders, using a small coding topic.

## Emphasis

**Bold** for API names, *italic* for terms, ~~strikethrough~~ for deprecated advice,
and `inline code` for identifiers like `std::vector`.

## Code blocks

A Python example:

```python
def quicksort(xs):
    if len(xs) <= 1:
        return xs
    pivot, *rest = xs
    left  = [x for x in rest if x <  pivot]
    right = [x for x in rest if x >= pivot]
    return quicksort(left) + [pivot] + quicksort(right)

print(quicksort([3, 1, 4, 1, 5, 9, 2, 6]))
```

And the same idea in C++:

```cpp
#include <algorithm>
#include <vector>

void quicksort(std::vector<int>& v) {
    std::sort(v.begin(), v.end()); // ponytail: the lazy quicksort
}
```

## Lists

Steps to run it:

1. Save the file as `sort.py`
2. Run `python sort.py`
3. Read the output

Things to remember:

- Prefer the standard library
- Measure before optimizing
- Delete dead code

## Quote

> Premature optimization is the root of all evil. — Donald Knuth

## Table

| Algorithm | Average | Worst |
|-----------|---------|-------|
| Quicksort | O(n log n) | O(n²) |
| Mergesort | O(n log n) | O(n log n) |

## Link

See the [Qt documentation](https://doc.qt.io) for more on the renderer.
"""

def default_db_path():
    from pathlib import Path
    dir_ = QStandardPaths.writableLocation(QStandardPaths.AppDataLocation)
    return str(Path(dir_) / "recall.db")


class Store(QObject):
    changed = Signal()

    def __init__(self, db_path, parent=None):
        super().__init__(parent)
        from pathlib import Path
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(db_path)
        self._db.isolation_level = None  # autocommit, like QSqlQuery
        self._data_version = -1

        c = self._db
        c.execute("PRAGMA foreign_keys = ON")
        c.execute("PRAGMA journal_mode = WAL")
        c.execute("PRAGMA busy_timeout = 3000")
        c.execute(
            "CREATE TABLE IF NOT EXISTS documents ("
            " id INTEGER PRIMARY KEY,"
            " parent_id INTEGER REFERENCES documents(id) ON DELETE CASCADE,"
            " title TEXT NOT NULL,"
            " content TEXT NOT NULL DEFAULT '',"
            " created_at TEXT NOT NULL DEFAULT (datetime('now')),"
            " updated_at TEXT NOT NULL DEFAULT (datetime('now')))")
        c.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts USING fts5("
            " title, content, content='documents', content_rowid='id')")
        c.execute(
            "CREATE TRIGGER IF NOT EXISTS docs_ai AFTER INSERT ON documents BEGIN"
            " INSERT INTO docs_fts(rowid, title, content) VALUES (new.id, new.title, new.content);"
            " END")
        c.execute(
            "CREATE TRIGGER IF NOT EXISTS docs_ad AFTER DELETE ON documents BEGIN"
            " INSERT INTO docs_fts(docs_fts, rowid, title, content)"
            " VALUES ('delete', old.id, old.title, old.content);"
            " END")
        c.execute(
            "CREATE TRIGGER IF NOT EXISTS docs_au AFTER UPDATE ON documents BEGIN"
            " INSERT INTO docs_fts(docs_fts, rowid, title, content)"
            " VALUES ('delete', old.id, old.title, old.content);"
            " INSERT INTO docs_fts(rowid, title, content) VALUES (new.id, new.title, new.content);"
            " END")
        c.execute(
            "CREATE TABLE IF NOT EXISTS clarifications ("
            " id INTEGER PRIMARY KEY,"
            " doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,"
            " quoted_text TEXT NOT NULL,"
            " comment TEXT NOT NULL,"
            " created_at TEXT NOT NULL DEFAULT (datetime('now')))")

        if c.execute("SELECT COUNT(*) FROM documents").fetchone()[0] == 0:
            self.create_document("Welcome", WELCOME_MD, None)
        version = c.execute("PRAGMA user_version").fetchone()[0]
        if version < 1:
            self.create_document("Coding Example", CODING_EXAMPLE_MD, None)
            c.execute("PRAGMA user_version = 1")

    # --- GUI-facing ---

    @Slot(str, result="QVariantList")
    def search(self, query):
        # Quote each token so user input can't break FTS5 syntax; trailing * for prefix match.
        parts = ['"%s"*' % tok.replace('"', '""') for tok in query.split()]
        if not parts:
            return []
        rows = self._db.execute(
            "SELECT d.id, d.title, snippet(docs_fts, 1, '<b>', '</b>', '…', 12)"
            " FROM docs_fts JOIN documents d ON d.id = docs_fts.rowid"
            " WHERE docs_fts MATCH ? ORDER BY rank LIMIT 25",
            (" ".join(parts),)).fetchall()
        return [{"id": r[0], "title": r[1], "snippet": r[2]} for r in rows]

    @Slot(str, str, int, result=int)
    def createDoc(self, title, content, parent_id):
        doc_id, _ = self.create_document(title, content, parent_id if parent_id >= 0 else None)
        return doc_id

    @Slot(int, str, str, result=bool)
    def updateDoc(self, doc_id, title, content):
        ok, _ = self.update_document(doc_id, {"title": title, "content": content})
        return ok

    # --- "Request Clarification" annotations ---

    @Slot(int, str, str, result=int)
    def addClarification(self, doc_id, quote, comment):
        try:
            cur = self._db.execute(
                "INSERT INTO clarifications(doc_id, quoted_text, comment) VALUES (?, ?, ?)",
                (doc_id, quote, comment))
        except sqlite3.Error:
            return -1
        self.changed.emit()
        return cur.lastrowid

    @Slot(int, result=bool)
    def resolveClarification(self, clarification_id):
        cur = self._db.execute(
            "DELETE FROM clarifications WHERE id = ?", (clarification_id,))
        if cur.rowcount == 0:
            return False
        self.changed.emit()
        return True

    @Slot(int, result="QVariantList")
    def clarificationsFor(self, doc_id):
        return self.list_clarifications(doc_id)

    def list_clarifications(self, doc_id=-1):
        if doc_id >= 0:
            rows = self._db.execute(
                "SELECT id, doc_id, quoted_text, comment FROM clarifications"
                " WHERE doc_id = ? ORDER BY id", (doc_id,)).fetchall()
        else:
            rows = self._db.execute(
                "SELECT id, doc_id, quoted_text, comment FROM clarifications ORDER BY id").fetchall()
        return [{"id": r[0], "doc_id": r[1], "quoted_text": r[2], "comment": r[3]}
                for r in rows]

    # --- CRUD (used by the MCP server and the tree model) ---

    def list_documents(self):
        rows = self._db.execute(
            "SELECT id, parent_id, title FROM documents ORDER BY title COLLATE NOCASE").fetchall()
        return [{"id": r[0], "parent_id": r[1], "title": r[2]} for r in rows]

    @Slot(int, result="QVariantMap")
    def getDocument(self, doc_id):
        row = self._db.execute(
            "SELECT id, parent_id, title, content, created_at, updated_at"
            " FROM documents WHERE id = ?", (doc_id,)).fetchone()
        if row is None:
            return {}
        return {"id": row[0], "parent_id": row[1], "title": row[2],
                "content": row[3], "created_at": row[4], "updated_at": row[5]}

    def create_document(self, title, content, parent_id):
        """Returns (id, error); id is -1 on failure."""
        try:
            cur = self._db.execute(
                "INSERT INTO documents(parent_id, title, content) VALUES (?, ?, ?)",
                (parent_id, title, content))
        except sqlite3.Error as e:
            return -1, str(e)
        self.changed.emit()
        return cur.lastrowid, ""

    def update_document(self, doc_id, fields):
        """Returns (ok, error). Only provided fields change."""
        if fields.get("parent_id") is not None:
            # a document reparented under itself or a descendant becomes
            # unreachable from the tree root; walk up from the new parent
            # (visited-set guards against already-corrupt chains)
            pid, seen = fields["parent_id"], set()
            while pid is not None and pid not in seen:
                if pid == doc_id:
                    return False, "parent_id would create a cycle"
                seen.add(pid)
                row = self._db.execute(
                    "SELECT parent_id FROM documents WHERE id = ?", (pid,)).fetchone()
                if row is None:
                    break  # unknown parent: the FK constraint reports it
                pid = row[0]
        sets, binds = [], []
        for key in ("title", "content", "parent_id"):
            if key in fields:
                sets.append(f"{key} = ?")
                binds.append(fields[key])
        if not sets:
            return False, "no fields to update"
        sets.append("updated_at = datetime('now')")
        try:
            cur = self._db.execute(
                f"UPDATE documents SET {', '.join(sets)} WHERE id = ?", (*binds, doc_id))
        except sqlite3.Error as e:
            return False, str(e)
        if cur.rowcount == 0:
            return False, f"document {doc_id} not found"
        self.changed.emit()
        return True, ""

    def delete_document(self, doc_id):
        """Returns (ok, error)."""
        try:
            cur = self._db.execute("DELETE FROM documents WHERE id = ?", (doc_id,))
        except sqlite3.Error as e:
            return False, str(e)
        if cur.rowcount == 0:
            return False, f"document {doc_id} not found"
        self.changed.emit()
        return True, ""

    # emits changed() when another connection (e.g. the MCP server) wrote to the db
    @Slot()
    def checkExternalChanges(self):
        v = self._db.execute("PRAGMA data_version").fetchone()[0]
        if self._data_version >= 0 and v != self._data_version:
            self.changed.emit()
        self._data_version = v
