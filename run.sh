#!/usr/bin/env bash
# Launch the Recall GUI straight from this checkout's source (not the installed
# copy in site-packages), so a plain `git pull` is enough — no reinstall needed.
# Only the venv's dependencies (PySide6) are used; the code comes from here.
cd "$(dirname "$0")"
exec ./.venv/bin/python -m recall.main "$@"
