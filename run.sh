#!/usr/bin/env bash
# Launch the Recall GUI from this checkout's venv.
exec "$(dirname "$0")/.venv/bin/recall" "$@"
