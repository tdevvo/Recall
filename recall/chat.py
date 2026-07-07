# Chat agent: a conversational Claude Code session with full access to the
# Recall MCP tools, so you can ask it to read and edit the wiki in real time.
#
# Each user turn spawns the logged-in `claude` CLI headless (`-p`) with our MCP
# server wired in; the first turn's session id is reused with `--resume` on
# later turns so the conversation keeps its context. Edits the agent makes land
# in the shared database and the reader picks them up on the next change poll —
# we also nudge the poll as the stream reports tool calls, so they show live.
import json
import os
import shutil
import sys

from PySide6.QtCore import QObject, QProcess, QSettings, QTimer, Signal, Slot

from .mcp_server import client_config
from .revise import DEFAULT_MODEL

# the full recall toolset — chat can read, search and edit, unlike Revise which
# only needs the two write tools
CHAT_TOOLS = [
    "mcp__recall__list_documents",
    "mcp__recall__read_document",
    "mcp__recall__create_document",
    "mcp__recall__update_document",
    "mcp__recall__delete_document",
    "mcp__recall__search",
    "mcp__recall__list_clarifications",
    "mcp__recall__resolve_clarification",
    "mcp__recall__list_templates",
    "mcp__recall__read_template",
]
CHAT_TIMEOUT_MS = 600_000

CHAT_SYSTEM = (
    "You are the assistant for Recall, a wiki-like tree of Markdown documents. "
    "The provided tools read and edit that wiki, sharing its live database with "
    "the app the user is looking at. When the user asks you to add, change or "
    "reorganize documentation, make the edits with the tools rather than only "
    "describing them; consult the templates (list_templates / read_template) for "
    "the house style before writing. For questions that don't require edits, just "
    "answer.\n\n"
    "Your chat replies are shown in a narrow chat panel, so write them as short, "
    "plain conversational prose — one to three sentences confirming what you did or "
    "answering the question. Do NOT use Markdown headings, tables, code fences or "
    "long bulleted structures in the chat reply itself; at most use a short bit of "
    "**bold** or a couple of hyphen bullets. Put all detailed or structured "
    "content into the documents via the tools, not into the chat message."
)


class ChatAgent(QObject):
    turnStarted = Signal()
    turnFinished = Signal()
    assistantText = Signal(str)    # a completed assistant text block
    toolActivity = Signal(str)     # one line describing a tool call
    note = Signal(str)             # session/connection notices
    errorOccurred = Signal(str)

    def __init__(self, store, parent=None):
        super().__init__(parent)
        self._store = store
        self._cli = shutil.which("claude")
        self._busy = False
        self._session_id = ""
        self._out_buf = ""
        self._proc = None

    @Slot(result=bool)
    def available(self):
        return bool(self._cli)

    @Slot(result=bool)
    def busy(self):
        return self._busy

    def _model(self):
        return QSettings().value("ai/model", DEFAULT_MODEL)

    # start a fresh conversation: drop the resumed session so the next message
    # begins with no prior context
    @Slot()
    def reset(self):
        self._session_id = ""

    def _context_block(self, current_doc_id, referenced_ids):
        """Preamble telling the agent which document is in focus and which others
        the user @-referenced, so 'this document' resolves and cross-document
        edits target the right ids."""
        parts = []
        if current_doc_id is not None and current_doc_id >= 0:
            doc = self._store.getDocument(current_doc_id)
            if doc:
                parts.append(
                    f"The user is looking at document id {doc['id']} titled "
                    f"{doc['title']!r}. Unless they clearly mean another document, "
                    '"this document" / "the current document" / an unqualified edit '
                    "refers to this one. Its current content is:\n"
                    f'<document id="{doc["id"]}">\n{doc["content"]}\n</document>')
        refs = []
        for rid in (referenced_ids or []):
            try:
                rid = int(rid)
            except (TypeError, ValueError):
                continue
            if rid == current_doc_id:
                continue
            d = self._store.getDocument(rid)
            if d:
                refs.append(f"- id {d['id']}: {d['title']!r}")
        if refs:
            parts.append("The user referenced these documents with @ — read or "
                         "edit them by id as needed:\n" + "\n".join(refs))
        return "\n\n".join(parts)

    @Slot(str)
    @Slot(str, int, "QVariantList")
    def send(self, message, current_doc_id=-1, referenced_ids=None):
        message = message.strip()
        if not message or self._busy:
            return
        if not self._cli:
            self.errorOccurred.emit("Claude Code CLI not found on PATH")
            return

        ctx = self._context_block(current_doc_id, referenced_ids)
        prompt = f"<context>\n{ctx}\n</context>\n\n{message}" if ctx else message

        args = ["-p", prompt,
                "--mcp-config", json.dumps(client_config()),
                "--strict-mcp-config",
                "--tools", "",                       # drop built-ins; use MCP tools
                "--allowedTools", ",".join(CHAT_TOOLS),
                "--append-system-prompt", CHAT_SYSTEM,
                "--max-turns", "20",
                "--model", self._model(),
                "--output-format", "stream-json", "--verbose"]
        # keep the same underlying Claude session across turns for context
        if self._session_id:
            args += ["--resume", self._session_id]

        proc = QProcess(self)
        self._proc = proc
        self._out_buf = ""
        proc.readyReadStandardOutput.connect(lambda: self._emit_stream(proc))
        # neutral cwd: don't adopt whatever project (CLAUDE.md, hooks) the app
        # happened to be launched from
        proc.setWorkingDirectory(os.path.expanduser("~"))
        watchdog = QTimer(proc)
        watchdog.setSingleShot(True)
        watchdog.setInterval(CHAT_TIMEOUT_MS)
        watchdog.timeout.connect(proc.kill)
        proc.finished.connect(lambda code, _s: self._on_done(proc, code))

        self._busy = True
        self.turnStarted.emit()
        proc.start(self._cli, args)
        watchdog.start()

    @staticmethod
    def _short(text, limit):
        # keep internal newlines (nicer in the expanded Activity view); just trim
        # the ends and cap the total length
        text = text.strip()
        return text if len(text) <= limit else text[:limit] + "…"

    @staticmethod
    def _result_text(block):
        content = block.get("content")
        if isinstance(content, list):
            return "\n".join(c.get("text", "") for c in content
                             if isinstance(c, dict) and c.get("type") == "text")
        return content if isinstance(content, str) else ""

    def _emit_stream(self, proc):
        """Digest claude's stream-json events. The assistant's prose replies go to
        the conversation (assistantText); everything else — the commands it runs,
        their results, thinking and status — goes to the Activity timeline via
        toolActivity/note, so the chat stays clean while the log stays complete."""
        self._out_buf += bytes(proc.readAllStandardOutput()).decode("utf-8", "replace")
        while "\n" in self._out_buf:
            line, self._out_buf = self._out_buf.split("\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            t = msg.get("type")
            if msg.get("session_id"):
                self._session_id = msg["session_id"]
            if t == "system" and msg.get("subtype") == "init":
                self.note.emit(f"session started · model {msg.get('model', '?')}")
                bad = [s.get("name", "?") for s in msg.get("mcp_servers", [])
                       if s.get("status") != "connected"]
                if bad:
                    self.note.emit(f"! MCP server failed to connect: {', '.join(bad)}")
            elif t == "assistant":
                for b in msg.get("message", {}).get("content", []):
                    bt = b.get("type")
                    if bt == "text" and b.get("text", "").strip():
                        self.assistantText.emit(b["text"].strip())
                    elif bt == "thinking" and b.get("thinking", "").strip():
                        self.toolActivity.emit("thinking: " + self._short(b["thinking"], 4000))
                    elif bt == "tool_use":
                        name = b.get("name", "tool").replace("mcp__recall__", "")
                        args_s = json.dumps(b.get("input", {}), ensure_ascii=False)
                        self.toolActivity.emit(f"• {name}  {self._short(args_s, 4000)}")
            elif t == "user":
                # tool results the agent got back (list_documents output, etc.)
                for b in msg.get("message", {}).get("content", []):
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        out = self._result_text(b).strip()
                        if out:
                            self.toolActivity.emit("   ↳ " + self._short(out, 4000))
            elif t == "result":
                self.note.emit(f"— finished in {msg.get('duration_ms', 0) / 1000:.0f}s —")
        # the agent edits through the MCP server between poll ticks; check now so
        # its changes show in the reader as the stream reports them
        self._store.checkExternalChanges()

    def _on_done(self, proc, code):
        try:
            if code != 0:
                err = bytes(proc.readAllStandardError()).decode("utf-8", "replace")
                raise RuntimeError((err.strip() or f"claude exited with code {code}")[:300])
        except Exception as e:  # noqa: BLE001 — single funnel to the UI
            print(f"chat failed: {e}", file=sys.stderr)
            self.errorOccurred.emit(str(e))
        finally:
            self._busy = False
            self._proc = None
            self.turnFinished.emit()
            proc.deleteLater()
