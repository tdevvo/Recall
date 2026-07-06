# Tree of documents for the QML TreeView, rebuilt wholesale from the Store.
# Python port of src/doctreemodel.cpp.
from PySide6.QtCore import (QAbstractItemModel, QModelIndex, Qt, Slot)


class _Node:
    __slots__ = ("id", "title", "parent", "row", "children")

    def __init__(self):
        self.id = -1
        self.title = ""
        self.parent = None
        self.row = 0
        self.children = []


DOC_ID_ROLE = Qt.UserRole + 1


class DocTreeModel(QAbstractItemModel):
    def __init__(self, store, parent=None):
        super().__init__(parent)
        self._store = store
        self._root = _Node()
        self._by_id = {}
        self._rebuild()

    @Slot()
    def reload(self):
        self.beginResetModel()
        self._rebuild()
        self.endResetModel()

    def _rebuild(self):
        self._root.children = []
        self._by_id = {}
        docs = self._store.list_documents()  # already sorted by title

        parked = []
        for d in docs:
            node = _Node()
            node.id = d["id"]
            node.title = d["title"]
            self._by_id[node.id] = node
            parked.append(node)
        # cycle guard: a node whose ancestor chain leads back to itself would
        # drop out of the tree entirely (unreachable from the root) — park it
        # at the root instead so corrupt data stays visible
        pid_of = {d["id"]: d["parent_id"] for d in docs}

        def in_cycle(node_id, pid):
            seen = set()
            while pid is not None and pid not in seen:
                if pid == node_id:
                    return True
                seen.add(pid)
                pid = pid_of.get(pid)
            return False

        for d, node in zip(docs, parked):
            pid = d["parent_id"]
            parent = self._root
            if pid is not None:
                p = self._by_id.get(pid)
                if p is not None and p is not node and not in_cycle(node.id, pid):
                    parent = p
            node.parent = parent
            node.row = len(parent.children)
            parent.children.append(node)

    def index(self, row, column, parent=QModelIndex()):
        p = parent.internalPointer() if parent.isValid() else self._root
        if column != 0 or row < 0 or row >= len(p.children):
            return QModelIndex()
        return self.createIndex(row, column, p.children[row])

    def parent(self, child):
        if not child.isValid():
            return QModelIndex()
        n = child.internalPointer()
        if n.parent is None or n.parent is self._root:
            return QModelIndex()
        return self.createIndex(n.parent.row, 0, n.parent)

    def rowCount(self, parent=QModelIndex()):
        p = parent.internalPointer() if parent.isValid() else self._root
        return len(p.children)

    def columnCount(self, parent=QModelIndex()):
        return 1

    def data(self, index, role=Qt.DisplayRole):
        if not index.isValid():
            return None
        n = index.internalPointer()
        if role == Qt.DisplayRole:
            return n.title
        if role == DOC_ID_ROLE:
            return n.id
        return None

    def roleNames(self):
        return {Qt.DisplayRole: b"display", DOC_ID_ROLE: b"docId"}

    # for preserving/restoring TreeView expansion state across model resets
    @Slot(int, result=QModelIndex)
    def indexForDoc(self, doc_id):
        n = self._by_id.get(doc_id)
        return self.createIndex(n.row, 0, n) if n is not None else QModelIndex()

    @Slot(QModelIndex, result=int)
    def docIdFor(self, index):
        return index.internalPointer().id if index.isValid() else -1
