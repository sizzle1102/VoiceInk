#!/usr/bin/env bash
set -euo pipefail
python3 "$(dirname "$0")/sync-upstream-test.py" "$@"
