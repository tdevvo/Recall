# Smoke test: store CRUD/search/clarifications + MCP server round-trip on a throwaway db.
# Run: .venv/bin/python tests/test_store.py
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


def test_store(tmp):
    from recall.store import Store

    store = Store(os.path.join(tmp, "t.db"))
    docs = store.list_documents()
    assert len(docs) == 2, docs  # Welcome + Coding Example seeds

    doc_id, err = store.create_document("Child", "hello *world*", docs[0]["id"])
    assert doc_id > 0, err
    assert store.getDocument(doc_id)["parent_id"] == docs[0]["id"]

    ok, err = store.update_document(doc_id, {"content": "quicksort notes"})
    assert ok, err
    hits = store.search("quicksort")
    assert any(h["id"] == doc_id for h in hits), hits
    assert store.search('"; DROP') == [] or True  # FTS quoting must not raise

    # porter stemming: inflected query finds the base form and vice versa
    ok, err = store.update_document(doc_id, {"content": "notes on optimizing tight loops at a café"})
    assert ok, err
    assert any(h["id"] == doc_id for h in store.search("optimized loop")), "stemming"
    assert any(h["id"] == doc_id for h in store.search("cafe")), "diacritics"

    # title hits rank above content hits
    t_id, _ = store.create_document("Zebra handbook", "nothing relevant", None)
    c_id, _ = store.create_document("Misc", "the zebra is mentioned in passing", None)
    ranked = [h["id"] for h in store.search("zebra")]
    assert ranked.index(t_id) < ranked.index(c_id), ranked
    store.delete_document(t_id)
    store.delete_document(c_id)

    cid = store.addClarification(doc_id, "quicksort", "expand this")
    assert cid > 0
    assert store.clarificationsFor(doc_id)[0]["comment"] == "expand this"
    assert store.resolveClarification(cid)
    assert store.list_clarifications() == []

    ok, _ = store.delete_document(doc_id)
    assert ok
    assert store.getDocument(doc_id) == {}

    # templates live in the same table but are kept out of list_documents/search
    seeded = store.list_templates()
    assert any(t["title"] == "House Style" for t in seeded), seeded
    tmpl_id, err = store.create_document("Naming rules", "use kebab-case", None,
                                         is_template=True)
    assert tmpl_id > 0, err
    assert store.getDocument(tmpl_id)["is_template"] is True
    assert not any(d["id"] == tmpl_id for d in store.list_documents())
    assert any(t["id"] == tmpl_id for t in store.list_templates())
    assert not any(h["id"] == tmpl_id for h in store.search("kebab")), "templates excluded from search"

    # moving a normal document into the Templates category (with a child subtree)
    parent_doc, _ = store.create_document("Movable", "top", None)
    child_doc, _ = store.create_document("Movable child", "under", parent_doc)
    ok, err = store.set_document_template(parent_doc, True)
    assert ok, err
    tids = {t["id"] for t in store.list_templates()}
    assert parent_doc in tids and child_doc in tids, "subtree moved to templates"
    assert not any(d["id"] in (parent_doc, child_doc) for d in store.list_documents())
    assert store.getDocument(parent_doc)["parent_id"] is None, "moved root detached to top level"
    # and back again
    assert store.set_document_template(parent_doc, False)[0]
    assert any(d["id"] == parent_doc for d in store.list_documents())


def test_mcp(tmp):
    env = dict(os.environ, XDG_DATA_HOME=tmp)
    reqs = "\n".join(json.dumps(r) for r in [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "create_document",
                    "arguments": {"title": "T", "content": "mcp test body"}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "search", "arguments": {"query": "mcp"}}},
    ]) + "\n"
    out = subprocess.run([sys.executable, "-m", "recall.mcp_server"],
                         input=reqs, capture_output=True, text=True, env=env,
                         cwd=os.path.join(os.path.dirname(__file__), ".."),
                         check=True).stdout.splitlines()
    replies = {json.loads(l)["id"]: json.loads(l) for l in out}
    assert replies[1]["result"]["serverInfo"]["name"] == "recall"
    assert len(replies[2]["result"]["tools"]) == 11
    assert "created document" in replies[3]["result"]["content"][0]["text"]
    # snippet() bolds the match: "<b>mcp</b> test body"
    assert "test body" in replies[4]["result"]["content"][0]["text"]


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as tmp:
        test_store(tmp)
    with tempfile.TemporaryDirectory() as tmp:
        test_mcp(tmp)
    print("OK")
