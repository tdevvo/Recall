# Recall — MCP connection debugging (Ubuntu)

The chat/agent talks to the app through a small MCP server that the `claude`
CLI launches. It works on Fedora but not Ubuntu, so these steps pin down the
Ubuntu-specific difference. Run them **on the Ubuntu machine** after a fresh
`git pull`, and send back the output.

---

## 0. Make sure Ubuntu is on the latest code

```bash
cd <your-recall-repo>
git pull
git log --oneline -1        # note the commit hash
```

Then launch the app with:

```bash
./run.sh
```

`run.sh` runs straight from source, so there's no stale installed copy.

**Check the title bar / toolbar — it must read `Recall  v1.3.0`.**
If it shows an older version (or no version), Ubuntu is still running old
code and that alone is the problem — fix by pulling and using `./run.sh`.

Version seen: ____________________

---

## 1. In-app self-test

Open the chat panel, send any message (e.g. "hello"), then look at the
**Activity** panel on the right. Copy every line that begins with `⚙`,
especially:

```
⚙ MCP self-test: <the command>
⚙ MCP self-test: OK …            ← or …
⚙ MCP self-test FAILED: <reason>
```

Paste them here:

```
<paste the ⚙ lines>
```

---

## 2. Terminal reproduction

This launches the server exactly the way the app does (same interpreter,
`python -c`, repo path baked in) but from a neutral directory, so any error
prints directly:

```bash
cd <your-recall-repo>
REPO=$(pwd); PY=$(./.venv/bin/python -c 'import sys;print(sys.executable)')
cd /tmp
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | "$PY" -c "import sys; sys.path.insert(0,'$REPO'); from recall.mcp_server import main; main()"
```

Paste the output:

```
<paste output>
```

### How to read it

- Output starts with `{"jsonrpc":"2.0","id":1,"result":…}`
  → the server runs fine on Ubuntu; the problem is elsewhere (DB path or code
  version), go by the self-test line in step 1.

- Output is a **Python traceback**, e.g.
  `ModuleNotFoundError: No module named 'PySide6'`
  → that's the cause. It usually means the `.venv` python used above does not
  actually have PySide6 — i.e. the GUI on Ubuntu is being launched some other
  way than this venv. Confirm which python has PySide6:

  ```bash
  ./.venv/bin/python -c "import PySide6; print('venv has PySide6', PySide6.__file__)"
  ```

---

## 3. Which interpreter is the app really using?

```bash
cd <your-recall-repo>
./.venv/bin/python -c "import sys; print('executable:', sys.executable)"
./.venv/bin/python -c "import sys; sys.path.insert(0,'.'); import json; from recall.mcp_server import client_config; print(json.dumps(client_config(), indent=2))"
```

The second command prints the exact server command the app hands to claude
(the `command` + `args`). Paste it here:

```
<paste config>
```

---

Send the version from step 0 plus the output of steps 1–3 and we can identify
the Ubuntu-specific cause.
