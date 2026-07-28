#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/voiceink-install-common.sh"

REMOTE="${VOICEINK_REMOTE:-origin}"
BRANCH="${VOICEINK_BRANCH:-main}"
WORKFLOW_FILE="${VOICEINK_WORKFLOW:-build-local-app.yml}"
ARTIFACT_NAME="${VOICEINK_ARTIFACT_NAME:-VoiceInk-app}"
ARTIFACT_CACHE="${VOICEINK_ARTIFACT_CACHE:-$REPO_ROOT/artifacts/VoiceInk-app.zip}"
SIGN_IDENTITY="${VOICEINK_SIGN_IDENTITY:-VoiceInk Local Code Signing}"
APP_DESTINATION="${VOICEINK_APP_DESTINATION:-/Applications/VoiceInk.app}"
BUNDLE_ID="${VOICEINK_BUNDLE_ID:-com.prakashjoshipax.VoiceInk}"
APP_PROCESS_NAME="${VOICEINK_PROCESS_NAME:-VoiceInk}"
TOKEN_KEYCHAIN_SERVICE="${VOICEINK_TOKEN_KEYCHAIN_SERVICE:-VoiceInk GitHub Token}"
TOKEN_KEYCHAIN_ACCOUNT="${VOICEINK_TOKEN_KEYCHAIN_ACCOUNT:-${USER:-default}}"
RELAUNCH="${VOICEINK_RELAUNCH:-1}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [VoiceInk-app.zip]

Without an argument, downloads and installs the latest available successful
$ARTIFACT_NAME artifact from $WORKFLOW_FILE on $BRANCH.

With a ZIP path, installs that artifact without accessing GitHub.
EOF
}

install_archive() {
  local archive_path="$1"
  local workdir="$2"
  local app_path

  app_path="$(
    voiceink_extract_artifact_zip "$archive_path" "$workdir" "$BUNDLE_ID"
  )"
  voiceink_sign_app "$app_path" "$SIGN_IDENTITY"
  voiceink_install_app \
    "$app_path" \
    "$APP_DESTINATION" \
    "$BUNDLE_ID" \
    "$APP_PROCESS_NAME" \
    "$RELAUNCH"
}

install_latest_archive() {
  local workdir="$1"
  local repo
  local latest_result
  local run_id
  local head_sha
  local download_url

  GITHUB_API_TOKEN="$(
    voiceink_read_token "$TOKEN_KEYCHAIN_SERVICE" "$TOKEN_KEYCHAIN_ACCOUNT"
  )"
  export GITHUB_API_TOKEN
  [[ -n "$GITHUB_API_TOKEN" ]] ||
    voiceink_die "GitHub token not found" || return 1

  cd "$REPO_ROOT"
  repo="${VOICEINK_REPO:-$(voiceink_infer_github_repo "$REMOTE")}" ||
    voiceink_die "Could not infer GitHub repo from remote $REMOTE" ||
    return 1

  latest_result="$(
    voiceink_find_latest_available_artifact \
      "$repo" \
      "$WORKFLOW_FILE" \
      "$BRANCH" \
      "$ARTIFACT_NAME" \
      "$workdir/latest"
  )" || return 1

  IFS=$'\t' read -r run_id head_sha download_url <<< "$latest_result"
  voiceink_log "Using successful run $run_id at $head_sha"
  voiceink_download_artifact_zip "$download_url" "$ARTIFACT_CACHE"
  install_archive "$ARTIFACT_CACHE" "$workdir"
}

main() {
  local archive_path=""
  local workdir
  local status=0

  if [[ "$#" -gt 1 ]]; then
    usage >&2
    return 2
  fi
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    return 0
  fi
  archive_path="${1:-}"

  voiceink_require_command unzip
  voiceink_require_command ditto
  voiceink_require_command codesign
  voiceink_require_command security
  voiceink_require_command plutil
  voiceink_require_command xattr
  voiceink_require_command osascript
  voiceink_require_command pgrep
  voiceink_require_command pkill
  voiceink_require_command find
  voiceink_assert_signing_identity "$SIGN_IDENTITY"

  if [[ -z "$archive_path" ]]; then
    voiceink_require_command curl
    voiceink_require_command git
    voiceink_require_command python3
  fi

  workdir="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-install.XXXXXX")"

  if [[ -n "$archive_path" ]]; then
    install_archive "$archive_path" "$workdir" || status=$?
  else
    install_latest_archive "$workdir" || status=$?
  fi

  rm -rf -- "$workdir"
  return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
