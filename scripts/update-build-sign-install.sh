#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/voiceink-install-common.sh"

SCRIPT_NAME="$(basename "$0")"
REMOTE="${VOICEINK_REMOTE:-origin}"
BRANCH="${VOICEINK_BRANCH:-main}"
SYNC_WORKFLOW="${VOICEINK_SYNC_WORKFLOW:-sync-upstream.yml}"
BUILD_WORKFLOW="${VOICEINK_WORKFLOW:-build-local-app.yml}"
ARTIFACT_NAME="${VOICEINK_ARTIFACT_NAME:-VoiceInk-app}"
SIGN_IDENTITY="${VOICEINK_SIGN_IDENTITY:-VoiceInk Local Code Signing}"
APP_DESTINATION="${VOICEINK_APP_DESTINATION:-/Applications/VoiceInk.app}"
BUNDLE_ID="${VOICEINK_BUNDLE_ID:-com.prakashjoshipax.VoiceInk}"
APP_PROCESS_NAME="${VOICEINK_PROCESS_NAME:-VoiceInk}"
TOKEN_KEYCHAIN_SERVICE="${VOICEINK_TOKEN_KEYCHAIN_SERVICE:-VoiceInk GitHub Token}"
TOKEN_KEYCHAIN_ACCOUNT="${VOICEINK_TOKEN_KEYCHAIN_ACCOUNT:-${USER:-default}}"
RELAUNCH="${VOICEINK_RELAUNCH:-1}"

SKIP_SYNC=0
SKIP_INSTALL=0
KEEP_WORKDIR=0
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Synchronizes this fork through GitHub Actions, automatically merges the sync
pull request, builds the resulting $BRANCH, downloads that exact artifact,
signs it with a local certificate, and installs it.

Options:
  --skip-sync      Build the current remote branch without upstream sync.
  --skip-install   Download and sign the app, but do not replace /Applications.
  --keep-workdir   Keep the temporary download/signing directory.
  --dry-run        Validate local configuration and print the planned steps.
  --no-relaunch    Do not reopen VoiceInk after installing the new app.
  -h, --help       Show this help.

Environment:
  VOICEINK_GITHUB_TOKEN or GITHUB_TOKEN
      Token used for workflow dispatch and artifact APIs.

  VOICEINK_SIGN_IDENTITY
      Local code signing identity. Default: VoiceInk Local Code Signing

  VOICEINK_BRANCH
      Remote fork branch to synchronize and build. Default: main
EOF
}

parse_args() {
  SKIP_SYNC=0
  SKIP_INSTALL=0
  KEEP_WORKDIR=0
  DRY_RUN=0
  RELAUNCH="${VOICEINK_RELAUNCH:-1}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-sync)
        SKIP_SYNC=1
        ;;
      --skip-install)
        SKIP_INSTALL=1
        ;;
      --keep-workdir)
        KEEP_WORKDIR=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --no-relaunch)
        RELAUNCH=0
        ;;
      -h|--help)
        usage
        return 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        return 1
        ;;
    esac
    shift
  done
}

sign_app() {
  voiceink_sign_app "$1" "$SIGN_IDENTITY"
}

install_app() {
  voiceink_install_app \
    "$1" \
    "$APP_DESTINATION" \
    "$BUNDLE_ID" \
    "$APP_PROCESS_NAME" \
    "$RELAUNCH"
}

run_remote_update() {
  local repo="$1"
  local workdir="$2"
  local artifact_cache="$3"
  local timestamp
  local sync_request_id
  local build_request_id
  local sync_run_id=""
  local main_sha
  local build_run_id
  local app_path

  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  sync_request_id="sync-install-$timestamp"
  build_request_id="build-install-$timestamp"

  if [[ "$SKIP_SYNC" != "1" ]]; then
    voiceink_log "Dispatching upstream sync: $sync_request_id"
    voiceink_dispatch_workflow \
      "$repo" \
      "$SYNC_WORKFLOW" \
      "$BRANCH" \
      "$sync_request_id" \
      '{"auto_merge":true}' \
      "$workdir/sync-dispatch.json"
    sync_run_id="$(
      voiceink_wait_for_workflow_run \
        "$repo" \
        "$SYNC_WORKFLOW" \
        "$BRANCH" \
        "$sync_request_id" \
        "" \
        "$workdir/sync"
    )" || return 1
    voiceink_log "Upstream sync completed in run $sync_run_id"
  else
    voiceink_log "Skipping upstream sync"
  fi

  main_sha="$(
    voiceink_remote_branch_sha "$repo" "$BRANCH" "$workdir"
  )" || return 1
  [[ -n "$main_sha" ]] ||
    voiceink_die "Remote $BRANCH has no head SHA" || return 1

  voiceink_log "Dispatching build for $BRANCH at $main_sha"
  voiceink_dispatch_workflow \
    "$repo" \
    "$BUILD_WORKFLOW" \
    "$BRANCH" \
    "$build_request_id" \
    '{}' \
    "$workdir/build-dispatch.json"
  build_run_id="$(
    voiceink_wait_for_workflow_run \
      "$repo" \
      "$BUILD_WORKFLOW" \
      "$BRANCH" \
      "$build_request_id" \
      "$main_sha" \
      "$workdir/build"
  )" || return 1

  voiceink_log "Downloading $ARTIFACT_NAME from run $build_run_id"
  voiceink_download_run_artifact_zip \
    "$repo" \
    "$build_run_id" \
    "$ARTIFACT_NAME" \
    "$artifact_cache" \
    "$workdir/download"

  app_path="$(
    voiceink_extract_artifact_zip \
      "$artifact_cache" \
      "$workdir/staging" \
      "$BUNDLE_ID"
  )" || return 1
  sign_app "$app_path"

  if [[ "$SKIP_INSTALL" == "1" ]]; then
    KEEP_WORKDIR=1
    voiceink_log "Signed app is ready at $app_path"
    return 0
  fi

  install_app "$app_path"
}

main() {
  local parse_status=0
  local root
  local repo
  local artifact_cache
  local workdir
  local status=0

  parse_args "$@" || parse_status=$?
  if [[ "$parse_status" == "2" ]]; then
    return 0
  fi
  if [[ "$parse_status" != "0" ]]; then
    return "$parse_status"
  fi

  voiceink_require_command curl
  voiceink_require_command unzip
  voiceink_require_command ditto
  voiceink_require_command codesign
  voiceink_require_command security
  voiceink_require_command git
  voiceink_require_command python3
  voiceink_require_command plutil
  voiceink_require_command xattr
  voiceink_require_command osascript
  voiceink_require_command pgrep
  voiceink_require_command pkill
  voiceink_require_command find

  root="$(voiceink_repo_root)" ||
    voiceink_die "Run this script inside the VoiceInk repository" ||
    return 1
  cd "$root"

  repo="${VOICEINK_REPO:-$(voiceink_infer_github_repo "$REMOTE")}" ||
    voiceink_die "Could not infer GitHub repo from remote $REMOTE" ||
    return 1
  artifact_cache="${VOICEINK_ARTIFACT_CACHE:-$REPO_ROOT/artifacts/VoiceInk-app.zip}"

  GITHUB_API_TOKEN="$(
    voiceink_read_token "$TOKEN_KEYCHAIN_SERVICE" "$TOKEN_KEYCHAIN_ACCOUNT"
  )"
  export GITHUB_API_TOKEN
  [[ -n "$GITHUB_API_TOKEN" ]] ||
    voiceink_die "GitHub token not found" || return 1
  voiceink_assert_signing_identity "$SIGN_IDENTITY"

  voiceink_log "Repository: $repo"
  voiceink_log "Branch: $BRANCH"
  voiceink_log "Sync workflow: $SYNC_WORKFLOW"
  voiceink_log "Build workflow: $BUILD_WORKFLOW"
  voiceink_log "Install destination: $APP_DESTINATION"

  if [[ "$DRY_RUN" == "1" ]]; then
    if [[ "$SKIP_SYNC" == "1" ]]; then
      voiceink_log "Dry run: build remote $BRANCH without sync"
    else
      voiceink_log "Dry run: sync and auto-merge upstream into remote $BRANCH"
    fi
    voiceink_log "Dry run: build, download, sign, and install"
    return 0
  fi

  workdir="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-update.XXXXXX")"
  run_remote_update "$repo" "$workdir" "$artifact_cache" || status=$?

  if [[ "$KEEP_WORKDIR" == "1" ]]; then
    voiceink_log "Keeping workdir: $workdir"
  else
    rm -rf -- "$workdir"
  fi

  if [[ "$status" == "0" ]]; then
    voiceink_log "VoiceInk update complete"
  fi
  return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
