#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATER_LIBRARY="$(mktemp /private/tmp/voiceink-updater-library.XXXXXX)"
trap 'rm -f "$UPDATER_LIBRARY"' EXIT

# Load updater functions without executing main.
# shellcheck disable=SC1090
sed '$d' "$TEST_ROOT/scripts/update-build-sign-install.sh" > "$UPDATER_LIBRARY"
source "$UPDATER_LIBRARY"

if ! (
  require_command() { :; }
  repo_root() { printf '%s\n' "$TEST_ROOT"; }
  infer_github_repo() { printf '%s\n' 'example/voiceink'; }
  read_token() { printf '%s' 'test-token'; }
  assert_clean_tree() { :; }
  assert_signing_identity() { :; }
  sync_from_upstream() { :; }
  github_api() { :; }
  wait_for_workflow_run() { printf '%s' '1'; }
  download_artifact() {
    local workdir="$3"
    mkdir -p "$workdir/app/VoiceInk.app"
    printf '%s' "$workdir/app/VoiceInk.app"
  }
  sign_app() { :; }
  install_app() { :; }
  git() {
    if [[ "${1:-}" == 'rev-parse' ]]; then
      printf '%s\n' '0123456789abcdef'
    fi
  }

  main
); then
  echo 'expected a successful update to exit cleanly after cleanup' >&2
  exit 1
fi

echo 'update-build-sign-install cleanup test passed'
