# AI revise: have Claude address a document's clarification requests.
# Two backends, both async (no threads, no GUI blocking):
#  - "claude-code": spawn the logged-in Claude Code CLI headless (subscription
#    billing); it edits through our own MCP server, so the reader updates live.
#  - "api": Anthropic Messages API via QtNetwork (needs an API key).
import json
import os
import shutil
import sys

from PySide6.QtCore import QObject, QProcess, QSettings, QTimer, Signal, Slot
from PySide6.QtNetwork import (QNetworkAccessManager, QNetworkReply,
                               QNetworkRequest)
from PySide6.QtCore import QUrl

from .mcp_server import client_config

API_URL = "https://api.anthropic.com/v1/messages"
# sonnet: revisions are mechanical editing — opus quota is wasted on them
DEFAULT_MODEL = "claude-sonnet-5"
# token diet: the doc and requests are embedded in the prompt, so the agent
# only ever needs these two tools — no reads, no built-in toolset
CLI_TOOLS = ["mcp__recall__update_document", "mcp__recall__resolve_clarification"]
CLI_TIMEOUT_MS = 600_000

SYSTEM = (
    "You revise wiki documents written in Markdown. Address every clarification "
    "request by expanding or clarifying the relevant passages; keep the rest of "
    "the document and its style intact. Respond with the complete updated document."
)

# structured outputs guarantee the reply is exactly {"content": "<markdown>"}
OUTPUT_SCHEMA = {
    "type": "json_schema",
    "schema": {
        "type": "object",
        "properties": {"content": {"type": "string"}},
        "required": ["content"],
        "additionalProperties": False,
    },
}


class Reviser(QObject):
    started = Signal(int)   # doc id
    finished = Signal(int)  # doc id
    error = Signal(str)

    registerResult = Signal(bool, str)  # Claude Code MCP registration outcome
    outputLine = Signal(str)            # live progress from the claude CLI

    def __init__(self, store, parent=None):
        super().__init__(parent)
        self._store = store
        self._nam = QNetworkAccessManager(self)
        self._busy = False
        self._cli = shutil.which("claude")
        self._out_buf = ""

    # --- settings (env var wins; QSettings is the fallback) ---

    @Slot(result=bool)
    def cliAvailable(self):
        return bool(self._cli)

    @Slot(result=str)
    def backend(self):
        default = "claude-code" if self._cli else "api"
        return QSettings().value("ai/backend", default)

    @Slot(result=bool)
    def ready(self):
        """Can revise() run with the current backend/config?"""
        if self.backend() == "claude-code":
            return bool(self._cli)
        return bool(self._api_key())

    @Slot(result=str)
    def savedApiKey(self):
        return QSettings().value("ai/apiKey", "")

    @Slot(result=str)
    def model(self):
        return QSettings().value("ai/model", DEFAULT_MODEL)

    @Slot(result=bool)
    def showTerminal(self):
        return QSettings().value("ai/showTerminal", True, type=bool)

    @Slot(str, str, str, bool)
    def saveSettings(self, backend, api_key, model, show_terminal):
        s = QSettings()
        s.setValue("ai/backend", backend)
        s.setValue("ai/apiKey", api_key.strip())
        s.setValue("ai/model", model.strip() or DEFAULT_MODEL)
        s.setValue("ai/showTerminal", show_terminal)

    def _api_key(self):
        return os.environ.get("ANTHROPIC_API_KEY") or self.savedApiKey()

    # --- Claude Code MCP registration (for the user's own interactive sessions;
    #     the Revise button itself passes the config inline and needs none) ---

    @Slot()
    def registerMcp(self):
        server = client_config()["mcpServers"]["recall"]
        proc = QProcess(self)
        proc.finished.connect(lambda code, _s: self._on_register_done(proc, code))
        proc.start(self._cli, ["mcp", "add", "--scope", "user", "recall", "--",
                               server["command"], *server["args"]])

    def _on_register_done(self, proc, code):
        err = bytes(proc.readAllStandardError()).decode("utf-8", "replace")
        if code == 0:
            self.registerResult.emit(True, "Registered ✓")
        elif "already exists" in err:
            self.registerResult.emit(True, "Already registered ✓")
        else:
            self.registerResult.emit(False, (err.strip() or "registration failed")[:200])
        proc.deleteLater()

    # --- revise ---

    @Slot(int)
    def revise(self, doc_id):
        if self._busy:
            return
        doc = self._store.getDocument(doc_id)
        clars = self._store.list_clarifications(doc_id)
        if not doc or not clars:
            return
        if self.backend() == "claude-code":
            self._revise_cli(doc_id, doc, clars)
            return
        key = self._api_key()
        if not key:
            self.error.emit("No API key configured")
            return

        clar_lines = "\n".join(
            f'- Regarding "{c["quoted_text"]}": {c["comment"]}' for c in clars)
        prompt = (
            f"Here is a wiki document titled {doc['title']!r}:\n\n"
            f"<document>\n{doc['content']}\n</document>\n\n"
            "The reader has requested clarification on these passages:\n"
            f"{clar_lines}\n\n"
            "Revise the document to address every request."
        )
        body = {
            "model": self.model(),
            "max_tokens": 16000,
            "thinking": {"type": "adaptive"},
            "system": SYSTEM,
            # effort defaults to "high"; revisions are mechanical edits, so
            # "medium" trims thinking time noticeably without hurting quality
            "output_config": {"format": OUTPUT_SCHEMA, "effort": "medium"},
            "messages": [{"role": "user", "content": prompt}],
        }

        req = QNetworkRequest(QUrl(API_URL))
        req.setHeader(QNetworkRequest.ContentTypeHeader, "application/json")
        req.setRawHeader(b"x-api-key", key.encode())
        req.setRawHeader(b"anthropic-version", b"2023-06-01")
        req.setTransferTimeout(300_000)  # adaptive thinking can take a while

        self._busy = True
        self.started.emit(doc_id)
        reply = self._nam.post(req, json.dumps(body).encode())
        reply.finished.connect(lambda: self._on_reply(reply, doc_id))

    def _on_reply(self, reply, doc_id):
        try:
            data = bytes(reply.readAll()).decode("utf-8", "replace")
            if reply.error() != QNetworkReply.NetworkError.NoError and not data:
                raise RuntimeError(reply.errorString())
            msg = json.loads(data)
            if msg.get("type") == "error":
                raise RuntimeError(msg["error"].get("message", "API error"))
            if msg.get("stop_reason") == "refusal":
                raise RuntimeError("The model declined to revise this document")
            if msg.get("stop_reason") == "max_tokens":
                raise RuntimeError("Revision was cut off — document too large")
            text = next(b["text"] for b in msg["content"] if b.get("type") == "text")
            content = json.loads(text)["content"]

            ok, err = self._store.update_document(doc_id, {"content": content})
            if not ok:
                raise RuntimeError(err)
            # the requests were addressed in the text; clear their annotations
            for c in self._store.list_clarifications(doc_id):
                self._store.resolveClarification(c["id"])
            self.finished.emit(doc_id)
        except Exception as e:  # noqa: BLE001 — single funnel to the UI
            print(f"revise failed: {e}", file=sys.stderr)
            self.error.emit(str(e))
        finally:
            self._busy = False
            reply.deleteLater()

    # --- Claude Code backend: headless `claude -p`, editing via our MCP server,
    #     so the GUI's data_version poll shows the changes as they land ---

    def _revise_cli(self, doc_id, doc, clars):
        if not self._cli:
            self.error.emit("Claude Code CLI not found on PATH")
            return
        # everything is in the prompt: no read round-trips, fewer turns
        clar_lines = "\n".join(
            f'- id {c["id"]}, regarding "{c["quoted_text"]}": {c["comment"]}'
            for c in clars)
        prompt = (
            f"Recall document {doc_id} titled {doc['title']!r} contains:\n\n"
            f"<document>\n{doc['content']}\n</document>\n\n"
            "Pending clarification requests:\n"
            f"{clar_lines}\n\n"
            "Revise the document's markdown to address every request; keep the rest "
            "of the text and style intact. Then call update_document with "
            f"id {doc_id} and the complete revised content, and resolve_clarification "
            "for each request id above. Do not do anything else."
        )
        args = ["-p", prompt,
                "--mcp-config", json.dumps(client_config()),
                "--strict-mcp-config",           # don't load other MCP servers' tools
                "--tools", *CLI_TOOLS,           # only these two tool definitions
                "--allowedTools", ",".join(CLI_TOOLS),
                "--max-turns", "8",
                "--model", self.model(),
                # line-delimited progress events for the in-app console
                "--output-format", "stream-json", "--verbose"]
        proc = QProcess(self)
        self._out_buf = ""
        proc.readyReadStandardOutput.connect(lambda: self._emit_stream(proc))
        # neutral cwd: don't adopt whatever project (CLAUDE.md, hooks) the app
        # happened to be launched from
        proc.setWorkingDirectory(os.path.expanduser("~"))
        watchdog = QTimer(proc)
        watchdog.setSingleShot(True)
        watchdog.setInterval(CLI_TIMEOUT_MS)
        watchdog.timeout.connect(proc.kill)
        proc.finished.connect(lambda code, _s: self._on_cli_done(proc, code, doc_id))

        self._busy = True
        self.started.emit(doc_id)
        proc.start(self._cli, args)
        watchdog.start()

    def _emit_stream(self, proc):
        """Digest claude's stream-json events into console-friendly lines."""
        self._out_buf += bytes(proc.readAllStandardOutput()).decode("utf-8", "replace")
        while "\n" in self._out_buf:
            line, self._out_buf = self._out_buf.split("\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                self.outputLine.emit(line)
                continue
            t = msg.get("type")
            if t == "system" and msg.get("subtype") == "init":
                self.outputLine.emit(f"session started · model {msg.get('model', '?')}")
            elif t == "assistant":
                for b in msg.get("message", {}).get("content", []):
                    if b.get("type") == "text" and b.get("text", "").strip():
                        self.outputLine.emit(b["text"].strip())
                    elif b.get("type") == "tool_use":
                        args_s = json.dumps(b.get("input", {}), ensure_ascii=False)
                        if len(args_s) > 140:
                            args_s = args_s[:140] + "…"
                        name = b.get("name", "tool").replace("mcp__recall__", "")
                        self.outputLine.emit(f"⏺ {name} {args_s}")
            elif t == "result":
                self.outputLine.emit(f"— finished in {msg.get('duration_ms', 0) / 1000:.0f}s —")
        # the agent writes through the MCP server between poll ticks; check now
        # so its edits show in the reader as soon as the stream reports them
        self._store.checkExternalChanges()

    def _on_cli_done(self, proc, code, doc_id):
        try:
            if code != 0:
                err = bytes(proc.readAllStandardError()).decode("utf-8", "replace")
                raise RuntimeError((err.strip() or f"claude exited with code {code}")[:300])
            # the agent edited + resolved via MCP; clear anything it left behind
            for c in self._store.list_clarifications(doc_id):
                self._store.resolveClarification(c["id"])
            self.finished.emit(doc_id)
        except Exception as e:  # noqa: BLE001 — single funnel to the UI
            print(f"revise failed: {e}", file=sys.stderr)
            self.error.emit(str(e))
        finally:
            self._busy = False
            proc.deleteLater()
