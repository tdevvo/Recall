# Recall MCP server — stdio transport, newline-delimited JSON-RPC 2.0.
# Exposes CRUD + search over the shared Recall document database.
# Python port of src/mcp_main.cpp; hand-rolled like the original (no SDK dependency).
import json
import sys

from PySide6.QtCore import QCoreApplication

from .store import Store, default_db_path


def client_config():
    """MCP client config for this install: the recall-mcp console script from
    this environment (venv/pipx), falling back to PATH. An absolute path —
    clients spawn the server from an arbitrary cwd with their own PATH."""
    import shutil
    from pathlib import Path
    local = Path(sys.executable).parent / "recall-mcp"
    cmd = str(local) if local.exists() else shutil.which("recall-mcp")
    if cmd:
        return {"mcpServers": {"recall": {"command": cmd, "args": []}}}
    return {"mcpServers": {"recall": {"command": sys.executable,
                                      "args": ["-m", "recall.mcp_server"]}}}


def _tool(name, desc, props, required):
    return {"name": name,
            "description": desc,
            "inputSchema": {"type": "object", "properties": props, "required": required}}


_ID = {"type": "integer", "description": "Document id"}
_TITLE = {"type": "string", "description": "Document title"}
_CONTENT = {"type": "string",
            "description": "Document body: Markdown, or raw HTML if it starts with '<'"}
_PARENT = {"type": "integer",
           "description": "Parent document id; omit for a top-level document"}

TOOLS = [
    _tool("list_documents",
          "List all documents as a flat array of {id, parent_id, title}; parent_id is null "
          "for top-level documents.",
          {}, []),
    _tool("read_document", "Read a document's full record including its content.",
          {"id": _ID}, ["id"]),
    _tool("create_document", "Create a new document. Returns the new document's id.",
          {"title": _TITLE, "content": _CONTENT, "parent_id": _PARENT}, ["title", "content"]),
    _tool("update_document",
          "Update a document's title, content and/or parent_id. Only provided fields change.",
          {"id": _ID, "title": _TITLE, "content": _CONTENT, "parent_id": _PARENT}, ["id"]),
    _tool("delete_document", "Delete a document and all of its descendants.",
          {"id": _ID}, ["id"]),
    _tool("search", "Full-text search over titles and content. Returns matches with snippets.",
          {"query": {"type": "string"}}, ["query"]),
    _tool("list_clarifications",
          "List pending 'Request Clarification' annotations as {id, doc_id, quoted_text, "
          "comment}. Each one is a request from the user to expand or clarify the quoted "
          "text of that document according to the comment. After editing the document to "
          "address a request, call resolve_clarification with its id.",
          {}, []),
    _tool("resolve_clarification",
          "Remove a clarification annotation once its request has been addressed in the "
          "document text.",
          {"id": {"type": "integer", "description": "Clarification id"}}, ["id"]),
]


def _text_result(text, is_error=False):
    r = {"content": [{"type": "text", "text": text}]}
    if is_error:
        r["isError"] = True
    return r


def _dumps_pretty(obj):
    # pretty-printed like QJsonDocument::toJson() in the C++ server
    return json.dumps(obj, indent=4, ensure_ascii=False) + "\n"


def call_tool(store, name, args):
    if name == "list_documents":
        return _text_result(_dumps_pretty(store.list_documents()))
    if name == "read_document":
        doc = store.getDocument(int(args.get("id", 0)))
        if not doc:
            return _text_result(f"document {args.get('id', 0)} not found", True)
        return _text_result(_dumps_pretty(doc))
    if name == "create_document":
        if "title" not in args or "content" not in args:
            return _text_result("missing required arguments: title and content", True)
        parent_id = int(args["parent_id"]) if args.get("parent_id") is not None else None
        doc_id, err = store.create_document(args["title"], args["content"], parent_id)
        if doc_id < 0:
            return _text_result("create failed: " + err, True)
        return _text_result(f"created document {doc_id}")
    if name == "update_document":
        fields = {}
        if "title" in args:
            fields["title"] = args["title"]
        if "content" in args:
            fields["content"] = args["content"]
        if "parent_id" in args:
            fields["parent_id"] = None if args["parent_id"] is None else int(args["parent_id"])
        ok, err = store.update_document(int(args.get("id", 0)), fields)
        if not ok:
            return _text_result("update failed: " + err, True)
        return _text_result("ok")
    if name == "delete_document":
        ok, err = store.delete_document(int(args.get("id", 0)))
        if not ok:
            return _text_result("delete failed: " + err, True)
        return _text_result("ok")
    if name == "list_clarifications":
        return _text_result(_dumps_pretty(store.list_clarifications()))
    if name == "resolve_clarification":
        if not store.resolveClarification(int(args.get("id", 0))):
            return _text_result(f"clarification {args.get('id', 0)} not found", True)
        return _text_result("ok")
    if name == "search":
        return _text_result(_dumps_pretty(store.search(args.get("query", ""))))
    return _text_result("unknown tool: " + name, True)


def _reply(msg_id, result):
    print(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result},
                     separators=(",", ":"), ensure_ascii=False), flush=True)


def _reply_error(msg_id, code, message):
    print(json.dumps({"jsonrpc": "2.0", "id": msg_id,
                      "error": {"code": code, "message": message}},
                     separators=(",", ":"), ensure_ascii=False), flush=True)


def main():
    QCoreApplication.setOrganizationName("Recall")
    QCoreApplication.setApplicationName("Recall")
    store = Store(default_db_path())

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(msg, dict):
            continue
        method = msg.get("method", "")
        is_notification = "id" not in msg
        msg_id = msg.get("id")

        if method == "initialize":
            _reply(msg_id, {
                "protocolVersion": msg.get("params", {}).get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "recall", "version": "1.0"}})
        elif method == "tools/list":
            _reply(msg_id, {"tools": TOOLS})
        elif method == "tools/call":
            params = msg.get("params", {})
            _reply(msg_id, call_tool(store, params.get("name", ""),
                                     params.get("arguments", {}) or {}))
        elif method == "ping":
            _reply(msg_id, {})
        elif not is_notification:
            _reply_error(msg_id, -32601, "method not found: " + method)
    return 0


if __name__ == "__main__":
    sys.exit(main())
