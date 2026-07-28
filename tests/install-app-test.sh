#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_WORKDIR="$(mktemp -d /private/tmp/voiceink-install-app.XXXXXX)"
CALLS="$TEST_WORKDIR/calls.log"
trap 'rm -rf "$TEST_WORKDIR"' EXIT

export VOICEINK_ARTIFACT_CACHE="$TEST_WORKDIR/cache/VoiceInk-app.zip"
export VOICEINK_APP_DESTINATION="$TEST_WORKDIR/Applications/VoiceInk.app"
export VOICEINK_RELAUNCH=0

# shellcheck disable=SC1091
source "$TEST_ROOT/scripts/install-app.sh"

mkdir -p "$TEST_WORKDIR/fixtures"

cat > "$TEST_WORKDIR/fixtures/runs.json" <<'JSON'
{
  "total_count": 3,
  "workflow_runs": [
    {
      "id": 30,
      "head_sha": "sha-30",
      "status": "completed",
      "conclusion": "success",
      "html_url": "https://github.example/runs/30"
    },
    {
      "id": 29,
      "head_sha": "sha-29",
      "status": "completed",
      "conclusion": "success",
      "html_url": "https://github.example/runs/29"
    },
    {
      "id": 28,
      "head_sha": "sha-28",
      "status": "completed",
      "conclusion": "success",
      "html_url": "https://github.example/runs/28"
    }
  ]
}
JSON

cat > "$TEST_WORKDIR/fixtures/artifacts-30.json" <<'JSON'
{
  "total_count": 1,
  "artifacts": [
    {
      "id": 300,
      "name": "VoiceInk-app",
      "expired": true,
      "archive_download_url": "https://api.example/artifacts/30.zip"
    }
  ]
}
JSON

cat > "$TEST_WORKDIR/fixtures/artifacts-29.json" <<'JSON'
{
  "total_count": 1,
  "artifacts": [
    {
      "id": 290,
      "name": "unrelated",
      "expired": false,
      "archive_download_url": "https://api.example/artifacts/29.zip"
    }
  ]
}
JSON

cat > "$TEST_WORKDIR/fixtures/artifacts-28.json" <<'JSON'
{
  "total_count": 1,
  "artifacts": [
    {
      "id": 280,
      "name": "VoiceInk-app",
      "expired": false,
      "archive_download_url": "https://api.example/artifacts/28.zip"
    }
  ]
}
JSON

voiceink_github_api() {
  local url="$2"
  local output="$3"

  case "$url" in
    *'/actions/workflows/build-local-app.yml/runs?'*)
      cp "$TEST_WORKDIR/fixtures/runs.json" "$output"
      ;;
    *'/actions/runs/30/artifacts')
      cp "$TEST_WORKDIR/fixtures/artifacts-30.json" "$output"
      ;;
    *'/actions/runs/29/artifacts')
      cp "$TEST_WORKDIR/fixtures/artifacts-29.json" "$output"
      ;;
    *'/actions/runs/28/artifacts')
      cp "$TEST_WORKDIR/fixtures/artifacts-28.json" "$output"
      ;;
    *)
      echo "unexpected GitHub API URL: $url" >&2
      return 1
      ;;
  esac
}

latest_result="$(
  voiceink_find_latest_available_artifact \
    "sizzle1102/VoiceInk" \
    "build-local-app.yml" \
    "main" \
    "VoiceInk-app" \
    "$TEST_WORKDIR/latest"
)"

IFS=$'\t' read -r run_id head_sha download_url <<< "$latest_result"
[[ "$run_id" == "28" ]]
[[ "$head_sha" == "sha-28" ]]
[[ "$download_url" == "https://api.example/artifacts/28.zip" ]]

mkdir -p "$(dirname "$VOICEINK_ARTIFACT_CACHE")"
printf 'previous-cache\n' > "$VOICEINK_ARTIFACT_CACHE"

voiceink_github_download() {
  local output="$2"
  printf 'partial-download\n' > "$output"
  return 1
}

if voiceink_download_artifact_zip \
  "https://api.example/artifacts/failing.zip" \
  "$VOICEINK_ARTIFACT_CACHE"; then
  echo 'expected failed artifact download' >&2
  exit 1
fi

[[ "$(cat "$VOICEINK_ARTIFACT_CACHE")" == "previous-cache" ]] || {
  echo 'failed download overwrote the previous cache' >&2
  exit 1
}

voiceink_require_command() {
  :
}

voiceink_assert_signing_identity() {
  :
}

voiceink_read_token() {
  printf 'github-token-requested\n' >> "$CALLS"
  return 1
}

voiceink_extract_artifact_zip() {
  local archive_path="$1"
  local workdir="$2"
  printf 'extract:%s\n' "$archive_path" >> "$CALLS"
  mkdir -p "$workdir/app/VoiceInk.app"
  printf '%s' "$workdir/app/VoiceInk.app"
}

voiceink_sign_app() {
  printf 'sign:%s\n' "$1" >> "$CALLS"
}

voiceink_install_app() {
  printf 'install:%s\n' "$1" >> "$CALLS"
}

explicit_zip="$TEST_WORKDIR/explicit VoiceInk-app.zip"
printf 'explicit-zip\n' > "$explicit_zip"

main "$explicit_zip"

rg -Fx -- "extract:$explicit_zip" "$CALLS" >/dev/null
rg -q '^sign:' "$CALLS"
rg -q '^install:' "$CALLS"

if rg -q '^github-token-requested$' "$CALLS"; then
  echo 'explicit ZIP mode must not request GitHub credentials' >&2
  exit 1
fi

[[ "$(cat "$VOICEINK_ARTIFACT_CACHE")" == "previous-cache" ]] || {
  echo 'explicit ZIP mode overwrote the repository cache' >&2
  exit 1
}

echo 'install app test passed'
