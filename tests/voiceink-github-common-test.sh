#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_WORKDIR="$(mktemp -d /private/tmp/voiceink-github-common.XXXXXX)"
trap 'rm -rf "$TEST_WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$TEST_ROOT/scripts/lib/voiceink-install-common.sh"

voiceink_github_api() {
  local url="$2"
  local output="$3"

  case "$url" in
    *'/actions/workflows/build-local-app.yml/runs?'*)
      cat > "$output" <<'JSON'
{
  "workflow_runs": [
    {
      "id": 100,
      "display_title": "Build local VoiceInk app build-request",
      "head_sha": "expected-sha",
      "status": "completed",
      "conclusion": "success",
      "html_url": "https://github.example/runs/100"
    }
  ]
}
JSON
      ;;
    *'/actions/runs/100/artifacts')
      cat > "$output" <<'JSON'
{
  "artifacts": [
    {
      "id": 200,
      "name": "VoiceInk-app",
      "expired": false,
      "archive_download_url": "https://api.example/artifacts/200.zip"
    }
  ]
}
JSON
      ;;
    *'/actions/runs/100')
      cat > "$output" <<'JSON'
{
  "id": 100,
  "head_sha": "expected-sha",
  "status": "completed",
  "conclusion": "success",
  "html_url": "https://github.example/runs/100"
}
JSON
      ;;
    *'/git/ref/heads/main')
      cat > "$output" <<'JSON'
{"object": {"sha": "remote-main-sha"}}
JSON
      ;;
    *)
      echo "unexpected GitHub API URL: $url" >&2
      return 1
      ;;
  esac
}

voiceink_github_download() {
  printf 'downloaded-artifact\n' > "$2"
}

export VOICEINK_RUN_TIMEOUT_SECONDS=2
export VOICEINK_POLL_INTERVAL_SECONDS=1

run_id="$(
  voiceink_wait_for_workflow_run \
    'sizzle1102/VoiceInk' \
    'build-local-app.yml' \
    'main' \
    'build-request' \
    'expected-sha' \
    "$TEST_WORKDIR/new/wait"
)"
[[ "$run_id" == "100" ]]

remote_sha="$(
  voiceink_remote_branch_sha \
    'sizzle1102/VoiceInk' \
    'main' \
    "$TEST_WORKDIR/new/ref"
)"
[[ "$remote_sha" == "remote-main-sha" ]]

voiceink_download_run_artifact_zip \
  'sizzle1102/VoiceInk' \
  '100' \
  'VoiceInk-app' \
  "$TEST_WORKDIR/new/cache/VoiceInk-app.zip" \
  "$TEST_WORKDIR/new/download"

[[ "$(cat "$TEST_WORKDIR/new/cache/VoiceInk-app.zip")" == \
  "downloaded-artifact" ]]

if voiceink_wait_for_workflow_run \
  'sizzle1102/VoiceInk' \
  'build-local-app.yml' \
  'main' \
  'build-request' \
  'wrong-sha' \
  "$TEST_WORKDIR/mismatch" >/dev/null; then
  echo 'workflow wait accepted a run for the wrong SHA' >&2
  exit 1
fi

echo 'voiceink GitHub common test passed'
