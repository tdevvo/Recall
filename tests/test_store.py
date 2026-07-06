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

    cid = store.addClarification(doc_id, "quicksort", "expand this")
    assert cid > 0
    assert store.clarificationsFor(doc_id)[0]["comment"] == "expand this"
    assert store.resolveClarification(cid)
    assert store.list_clarifications() == []

    ok, _ = store.delete_document(doc_id)
    assert ok
    assert store.getDocument(doc_id) == {}


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
    assert len(replies[2]["result"]["tools"]) == 8
    assert "created document" in replies[3]["result"]["content"][0]["text"]
    # snippet() bolds the match: "<b>mcp</b> test body"
    assert "test body" in replies[4]["result"]["content"][0]["text"]


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as tmp:
        test_store(tmp)
    with tempfile.TemporaryDirectory() as tmp:
        test_mcp(tmp)
    print("OK")
