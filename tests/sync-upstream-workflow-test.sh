#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$TEST_ROOT/.github/workflows/sync-upstream.yml"

rg -U 'workflow_dispatch:\n[[:space:]]+inputs:' "$WORKFLOW" >/dev/null
rg 'request_id:' "$WORKFLOW" >/dev/null
rg 'auto_merge:' "$WORKFLOW" >/dev/null
rg 'gh pr list' "$WORKFLOW" >/dev/null
rg -- '--state open' "$WORKFLOW" >/dev/null
rg 'gh pr merge' "$WORKFLOW" >/dev/null
rg -- '--match-head-commit' "$WORKFLOW" >/dev/null
rg -- '--merge' "$WORKFLOW" >/dev/null

if rg -- '--admin' "$WORKFLOW" >/dev/null; then
  echo 'sync workflow must not bypass repository protections' >&2
  exit 1
fi

if rg -- '--auto' "$WORKFLOW" >/dev/null; then
  echo 'sync workflow must fail instead of silently enabling auto-merge' >&2
  exit 1
fi

echo 'sync upstream workflow contract test passed'
