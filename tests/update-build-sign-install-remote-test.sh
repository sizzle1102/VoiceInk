#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_WORKDIR="$(mktemp -d /private/tmp/voiceink-remote-update.XXXXXX)"
SUCCESS_CALLS="$TEST_WORKDIR/success.log"
FAILURE_CALLS="$TEST_WORKDIR/failure.log"
trap 'rm -rf "$TEST_WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$TEST_ROOT/scripts/update-build-sign-install.sh"

run_success_case() (
  voiceink_require_command() {
    :
  }
  voiceink_repo_root() {
    printf '%s\n' "$TEST_ROOT"
  }
  voiceink_infer_github_repo() {
    printf '%s\n' 'sizzle1102/VoiceInk'
  }
  voiceink_read_token() {
    printf '%s' 'test-token'
  }
  voiceink_assert_signing_identity() {
    :
  }
  voiceink_dispatch_workflow() {
    local workflow="$2"
    local ref="$3"
    local request_id="$4"
    local inputs_json="$5"
    printf 'dispatch:%s:%s:%s:%s\n' \
      "$workflow" "$ref" "$request_id" "$inputs_json" >> "$SUCCESS_CALLS"
  }
  voiceink_wait_for_workflow_run() {
    local workflow="$2"
    local request_id="$4"
    local expected_sha="$5"
    printf 'wait:%s:%s:%s\n' \
      "$workflow" "$request_id" "$expected_sha" >> "$SUCCESS_CALLS"
    if [[ "$workflow" == 'sync-upstream.yml' ]]; then
      printf '%s' 'sync-run-1'
    else
      printf '%s' 'build-run-2'
    fi
  }
  voiceink_remote_branch_sha() {
    printf 'remote-sha:%s\n' "$2" >> "$SUCCESS_CALLS"
    printf '%s' 'merged-main-sha'
  }
  voiceink_download_run_artifact_zip() {
    printf 'download:%s\n' "$2" >> "$SUCCESS_CALLS"
    mkdir -p "$(dirname "$4")"
    printf 'artifact\n' > "$4"
  }
  voiceink_extract_artifact_zip() {
    printf 'extract:%s\n' "$1" >> "$SUCCESS_CALLS"
    mkdir -p "$2/app/VoiceInk.app"
    printf '%s' "$2/app/VoiceInk.app"
  }
  voiceink_sign_app() {
    printf 'sign\n' >> "$SUCCESS_CALLS"
  }
  voiceink_install_app() {
    printf 'install\n' >> "$SUCCESS_CALLS"
  }

  require_command() {
    voiceink_require_command "$@"
  }
  repo_root() {
    voiceink_repo_root
  }
  infer_github_repo() {
    voiceink_infer_github_repo "${1:-origin}"
  }
  read_token() {
    voiceink_read_token \
      'VoiceInk GitHub Token' \
      "${USER:-default}"
  }
  assert_signing_identity() {
    voiceink_assert_signing_identity 'VoiceInk Local Code Signing'
  }
  assert_clean_tree() {
    echo 'local clean-tree gate must not be used' >&2
    return 1
  }
  sync_from_upstream() {
    echo 'local upstream sync must not be used' >&2
    return 1
  }

  export VOICEINK_ARTIFACT_CACHE="$TEST_WORKDIR/success-cache/VoiceInk-app.zip"
  main --no-relaunch
)

run_failure_case() (
  voiceink_require_command() {
    :
  }
  voiceink_repo_root() {
    printf '%s\n' "$TEST_ROOT"
  }
  voiceink_infer_github_repo() {
    printf '%s\n' 'sizzle1102/VoiceInk'
  }
  voiceink_read_token() {
    printf '%s' 'test-token'
  }
  voiceink_assert_signing_identity() {
    :
  }
  voiceink_dispatch_workflow() {
    printf 'dispatch:%s\n' "$2" >> "$FAILURE_CALLS"
  }
  voiceink_wait_for_workflow_run() {
    printf 'wait:%s\n' "$2" >> "$FAILURE_CALLS"
    return 1
  }
  voiceink_remote_branch_sha() {
    printf 'remote-sha\n' >> "$FAILURE_CALLS"
    return 1
  }
  voiceink_download_run_artifact_zip() {
    printf 'download\n' >> "$FAILURE_CALLS"
  }
  voiceink_sign_app() {
    printf 'sign\n' >> "$FAILURE_CALLS"
  }
  voiceink_install_app() {
    printf 'install\n' >> "$FAILURE_CALLS"
  }

  require_command() {
    voiceink_require_command "$@"
  }
  repo_root() {
    voiceink_repo_root
  }
  infer_github_repo() {
    voiceink_infer_github_repo "${1:-origin}"
  }
  read_token() {
    voiceink_read_token \
      'VoiceInk GitHub Token' \
      "${USER:-default}"
  }
  assert_signing_identity() {
    voiceink_assert_signing_identity 'VoiceInk Local Code Signing'
  }
  assert_clean_tree() {
    return 1
  }
  sync_from_upstream() {
    return 1
  }

  export VOICEINK_ARTIFACT_CACHE="$TEST_WORKDIR/failure-cache/VoiceInk-app.zip"
  main --no-relaunch
)

run_success_case

success_sequence="$(
  sed -E \
    -e 's/sync-install-[^:]+/sync-request/g' \
    -e 's/build-install-[^:]+/build-request/g' \
    "$SUCCESS_CALLS"
)"

printf '%s\n' "$success_sequence" |
  rg '^dispatch:sync-upstream\.yml:main:sync-request:.*auto_merge.*true' \
    >/dev/null
printf '%s\n' "$success_sequence" |
  rg '^wait:sync-upstream\.yml:sync-request:$' >/dev/null
printf '%s\n' "$success_sequence" |
  rg '^remote-sha:main$' >/dev/null
printf '%s\n' "$success_sequence" |
  rg '^dispatch:build-local-app\.yml:main:build-request:' >/dev/null
printf '%s\n' "$success_sequence" |
  rg '^wait:build-local-app\.yml:build-request:merged-main-sha$' >/dev/null

expected_tail="$(cat <<'EOF'
download:build-run-2
extract:ARTIFACT_CACHE
sign
install
EOF
)"
actual_tail="$(
  tail -n 4 "$SUCCESS_CALLS" |
    sed "s|$TEST_WORKDIR/success-cache/VoiceInk-app.zip|ARTIFACT_CACHE|"
)"
[[ "$actual_tail" == "$expected_tail" ]] || {
  echo 'remote updater did not download, sign, and install the exact build' >&2
  printf 'expected:\n%s\nactual:\n%s\n' "$expected_tail" "$actual_tail" >&2
  exit 1
}

if run_failure_case; then
  echo 'expected sync workflow failure to stop the updater' >&2
  exit 1
fi

if rg -q '^(remote-sha|download|sign|install)$' "$FAILURE_CALLS"; then
  echo 'sync failure allowed later update stages to run' >&2
  exit 1
fi

echo 'update-build-sign-install remote orchestration test passed'
