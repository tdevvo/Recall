# Recall

A wiki-like desktop app for building navigable trees of interactive documents,
tailored to quick and easy access to information.

- **Document tree** — organize Markdown/HTML documents hierarchically in a side panel
- **Native reader** — Markdown rendering with styled headings, dark code blocks with copy buttons
- **Full-text search** — SQLite FTS over titles and content from the search bar
- **Request Clarification** — highlight text in a document and ask for it to be expanded; requests show as gold inline highlights
- **AI revise** — send pending clarifications to Claude, which rewrites the document while updates stream into the reader; works with either the Claude Code CLI (subscription) or the Anthropic API (key)
- **MCP server** — exposes the document base to AI agents (list/read/create/update/delete/search, clarifications)

Built with Python and PySide6 (Qt Quick / QML, Material theme). No WebEngine —
rendering is native, so only `PySide6-Essentials` is required.

## Requirements

- Python 3.10+
- Linux, macOS, or Windows

## Installation

```bash
git clone git@github.com:tdevvo/Recall.git
cd Recall
python -m venv .venv
.venv/bin/pip install .
```

## Running

```bash
./run.sh            # launches the GUI from the checkout's venv
# or directly:
.venv/bin/recall
```

Documents are stored in a SQLite database in the platform data directory
(e.g. `~/.local/share/Recall/` on Linux), shared by the GUI and the MCP server.

## MCP server

The install also provides `recall-mcp`, a stdio MCP server. Register it with
Claude Code either from the app (☰ → MCP Server Info → Register with Claude
Code) or manually:

```bash
claude mcp add --scope user recall -- /path/to/.venv/bin/recall-mcp
```

The exact client config JSON for other MCP clients is shown in
☰ → MCP Server Info, with a copy button.

## AI revise

Open ☰ → AI Provider to pick a backend:

- **Claude Code** (default when the `claude` CLI is on PATH) — uses your
  subscription; no key needed. Revisions run headless through the app's own
  MCP server and stream into the reader.
- **Anthropic API** — paste an API key (or set `ANTHROPIC_API_KEY`).

With a document open and pending clarifications, the blue **Revise** button
sends them to Claude and applies the revised document live.

## Tests

```bash
.venv/bin/pip install pytest
.venv/bin/python -m pytest tests/
```
