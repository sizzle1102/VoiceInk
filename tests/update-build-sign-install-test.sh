#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_WORKDIR="$(mktemp -d /private/tmp/voiceink-updater-cleanup.XXXXXX)"
trap 'rm -rf "$TEST_WORKDIR"' EXIT

# shellcheck disable=SC1090
source "$TEST_ROOT/scripts/update-build-sign-install.sh"

if ! (
  voiceink_require_command() { :; }
  voiceink_repo_root() { printf '%s\n' "$TEST_ROOT"; }
  voiceink_infer_github_repo() { printf '%s\n' 'example/voiceink'; }
  voiceink_read_token() { printf '%s' 'test-token'; }
  voiceink_assert_signing_identity() { :; }
  voiceink_dispatch_workflow() { :; }
  voiceink_wait_for_workflow_run() {
    if [[ "$2" == 'sync-upstream.yml' ]]; then
      printf '%s' 'sync-run'
    else
      printf '%s' 'build-run'
    fi
  }
  voiceink_remote_branch_sha() { printf '%s' '0123456789abcdef'; }
  voiceink_download_run_artifact_zip() {
    mkdir -p "$(dirname "$4")"
    printf 'artifact\n' > "$4"
  }
  voiceink_extract_artifact_zip() {
    local workdir="$2"
    mkdir -p "$workdir/app/VoiceInk.app"
    printf '%s' "$workdir/app/VoiceInk.app"
  }
  voiceink_sign_app() { :; }
  voiceink_install_app() { :; }

  export VOICEINK_ARTIFACT_CACHE="$TEST_WORKDIR/test-artifact.zip"
  main
); then
  echo 'expected a successful update to exit cleanly after cleanup' >&2
  exit 1
fi

echo 'update-build-sign-install cleanup test passed'
