#!/usr/bin/env bash
set -euo pipefail
repo="${VIEWFLOW_REPO:-$HOME/data/viewflow}"
exec python3 "$repo/tools/viewflow-reverse-performance.py" "$@"
