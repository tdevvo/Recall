# Recall MCP server — stdio transport, newline-delimited JSON-RPC 2.0.
# Exposes CRUD + search over the shared Recall document database.
# Python port of src/mcp_main.cpp; hand-rolled like the original (no SDK dependency).
import json
import os
import sys

from PySide6.QtCore import QCoreApplication

from .store import Store, default_db_path


def client_config():
    """MCP client config that runs *this* package as the server via the current
    interpreter, spawned by the client from an arbitrary cwd with a sanitized
    environment. Two things are therefore baked into the argv rather than left to
    the environment:
      * the package directory (sys.path.insert) — so the import works without
        PYTHONPATH, which the client does not reliably forward;
      * the resolved database path — so the server opens the SAME database as the
        running app. Otherwise QStandardPaths/HOME can resolve a different
        default_db_path() under the client's environment and the server would edit
        a phantom empty database, making every tool call fail from the user's view.
    Resolved here, in the app's process, where both are correct."""
    from pathlib import Path
    pkg_parent = str(Path(__file__).resolve().parent.parent)
    db = default_db_path()
    boot = ("import sys; sys.path.insert(0, %r); "
            "from recall.mcp_server import main; sys.exit(main(%r))" % (pkg_parent, db))
    return {"mcpServers": {"recall": {
        "command": sys.executable,
        "args": ["-c", boot],
    }}}


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
    _tool("create_document",
          "Create a new document. Before writing, call list_templates and read any "
          "relevant template with read_template — templates hold the wiki's house "
          "style and structure rules that new documents must follow. Returns the new "
          "document's id.",
          {"title": _TITLE, "content": _CONTENT, "parent_id": _PARENT}, ["title", "content"]),
    _tool("update_document",
          "Update a document's title, content and/or parent_id. Only provided fields "
          "change. When rewriting content, follow the house style in the templates "
          "(see list_templates / read_template).",
          {"id": _ID, "title": _TITLE, "content": _CONTENT, "parent_id": _PARENT}, ["id"]),
    _tool("delete_document", "Delete a document and all of its descendants.",
          {"id": _ID}, ["id"]),
    _tool("set_template",
          "Move a document into the Templates category, or move a template back to a "
          "normal document, by flipping its type. 'Template' is a type flag on the "
          "document itself — NOT a folder — so to make something a template you set its "
          "type here rather than creating a 'Templates' parent and reparenting under it. "
          "The document and its whole sub-tree move together and the moved item becomes "
          "top-level in its new tree.",
          {"id": _ID,
           "is_template": {"type": "boolean",
                           "description": "true = make it a template; false = make it a normal document"}},
          ["id", "is_template"]),
    _tool("search", "Full-text search over titles and content. Returns matches with snippets.",
          {"query": {"type": "string"}}, ["query"]),
    _tool("list_templates",
          "List the wiki's templates as a flat array of {id, parent_id, title}. Templates "
          "are documents that describe the house style, structure and conventions to apply "
          "when creating or updating documents — consult them before writing.",
          {}, []),
    _tool("read_template",
          "Read a template's full record including its content (the instructions to follow). "
          "Use the ids returned by list_templates.",
          {"id": _ID}, ["id"]),
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
    if name == "set_template":
        if "is_template" not in args:
            return _text_result("missing required argument: is_template", True)
        ok, err = store.set_document_template(int(args.get("id", 0)), bool(args["is_template"]))
        if not ok:
            return _text_result("set_template failed: " + err, True)
        return _text_result("ok")
    if name == "list_templates":
        return _text_result(_dumps_pretty(store.list_templates()))
    if name == "read_template":
        doc = store.getDocument(int(args.get("id", 0)))
        if not doc or not doc.get("is_template"):
            return _text_result(f"template {args.get('id', 0)} not found", True)
        return _text_result(_dumps_pretty(doc))
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


def main(db_path=None):
    QCoreApplication.setOrganizationName("Recall")
    QCoreApplication.setApplicationName("Recall")
    # Use the DB path the app baked into our launch command. The client (claude)
    # spawns us with a sanitized environment, so QStandardPaths/HOME can resolve a
    # DIFFERENT default_db_path() than the running app — the server would then edit
    # a phantom empty database and every tool call would "fail" from the user's
    # view. An explicit path keeps the server on the app's real database.
    store = Store(db_path or os.environ.get("RECALL_DB") or default_db_path())

    # Read with readline(), NOT `for line in sys.stdin`: file iteration reads
    # ahead in blocks, so the client's first request (initialize) can sit unseen
    # in the buffer while the client waits for our reply — a deadlock the client
    # reports as "MCP server failed to connect". readline() returns each line as
    # soon as its newline arrives. (line_buffering keeps our replies flushed too.)
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass
    while True:
        line = sys.stdin.readline()
        if not line:
            break  # EOF: the client closed the pipe
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

        # a single failing request must never take the whole server down —
        # otherwise the first bad tool call disconnects the agent for the rest
        # of the session ("works for a call or two, then fails")
        try:
            if method == "initialize":
                _reply(msg_id, {
                    "protocolVersion": msg.get("params", {}).get("protocolVersion", "2024-11-05"),
                    "capabilities": {"tools": {"listChanged": False}},
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
        except Exception as e:  # noqa: BLE001 — keep serving after any single failure
            print(f"recall-mcp: {method} failed: {e}", file=sys.stderr)
            if not is_notification:
                # report it as a tool error so the agent can react and retry
                _reply(msg_id, _text_result(f"internal error: {e}", True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
