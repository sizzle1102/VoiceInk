#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

BRANCH="${VOICEINK_BRANCH:-main}"
REMOTE="${VOICEINK_REMOTE:-origin}"
UPSTREAM_REMOTE="${VOICEINK_UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${VOICEINK_UPSTREAM_BRANCH:-main}"
WORKFLOW_FILE="${VOICEINK_WORKFLOW:-build-local-app.yml}"
ARTIFACT_NAME="${VOICEINK_ARTIFACT_NAME:-VoiceInk-app}"
SIGN_IDENTITY="${VOICEINK_SIGN_IDENTITY:-VoiceInk Local Code Signing}"
APP_DESTINATION="${VOICEINK_APP_DESTINATION:-/Applications/VoiceInk.app}"
BUNDLE_ID="${VOICEINK_BUNDLE_ID:-com.prakashjoshipax.VoiceInk}"
APP_PROCESS_NAME="${VOICEINK_PROCESS_NAME:-VoiceInk}"
TOKEN_KEYCHAIN_SERVICE="${VOICEINK_TOKEN_KEYCHAIN_SERVICE:-VoiceInk GitHub Token}"
TOKEN_KEYCHAIN_ACCOUNT="${VOICEINK_TOKEN_KEYCHAIN_ACCOUNT:-${USER:-default}}"
RUN_TIMEOUT_SECONDS="${VOICEINK_RUN_TIMEOUT_SECONDS:-3600}"
POLL_INTERVAL_SECONDS="${VOICEINK_POLL_INTERVAL_SECONDS:-15}"
RELAUNCH="${VOICEINK_RELAUNCH:-1}"

SKIP_SYNC=0
SKIP_INSTALL=0
KEEP_WORKDIR=0
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Updates this fork from upstream, triggers the GitHub Actions local app build,
downloads the app artifact, signs it with a local certificate, and installs it.

Options:
  --skip-sync      Do not fetch/merge/push upstream changes before building.
  --skip-install   Download and sign the app, but do not replace /Applications.
  --keep-workdir   Keep the temporary download/signing directory.
  --dry-run        Validate local configuration and print the planned steps.
  --no-relaunch    Do not reopen VoiceInk after installing the new app.
  -h, --help       Show this help.

Environment:
  VOICEINK_GITHUB_TOKEN or GITHUB_TOKEN
      Token used for GitHub Actions dispatch/artifact APIs.

  VOICEINK_TOKEN_KEYCHAIN_SERVICE
      Keychain service name used when no token env var is set.
      Default: VoiceInk GitHub Token

  VOICEINK_SIGN_IDENTITY
      Local code signing identity name.
      Default: VoiceInk Local Code Signing

  VOICEINK_BRANCH
      Fork branch to update/build.
      Default: main
EOF
}

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
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

json_escape_payload() {
  REF="$1" REQUEST_ID="$2" python3 - <<'PY'
import json
import os

print(json.dumps({
    "ref": os.environ["REF"],
    "inputs": {"request_id": os.environ["REQUEST_ID"]},
}))
PY
}

github_api() {
  local method="$1"
  local url="$2"
  local output="$3"
  local data="${4:-}"

  local args=(
    --fail-with-body
    --silent
    --show-error
    --location
    --request "$method"
    --header "Accept: application/vnd.github+json"
    --header "Authorization: Bearer $GITHUB_API_TOKEN"
    --header "X-GitHub-Api-Version: 2022-11-28"
    --output "$output"
  )

  if [[ -n "$data" ]]; then
    args+=(--header "Content-Type: application/json" --data "$data")
  fi

  curl "${args[@]}" "$url"
}

github_download() {
  local url="$1"
  local output="$2"

  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --location \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer $GITHUB_API_TOKEN" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    --output "$output" \
    "$url"
}

read_token() {
  if [[ -n "${VOICEINK_GITHUB_TOKEN:-}" ]]; then
    printf '%s' "$VOICEINK_GITHUB_TOKEN"
    return 0
  fi

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf '%s' "$GITHUB_TOKEN"
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    local gh_token
    gh_token="$(gh auth token 2>/dev/null || true)"
    if [[ -n "$gh_token" ]]; then
      printf '%s' "$gh_token"
      return 0
    fi
  fi

  security find-generic-password \
    -a "$TOKEN_KEYCHAIN_ACCOUNT" \
    -s "$TOKEN_KEYCHAIN_SERVICE" \
    -w 2>/dev/null || true
}

infer_github_repo() {
  local remote_url
  remote_url="$(git config --get "remote.${REMOTE}.url")"

  case "$remote_url" in
    git@*:*)
      printf '%s' "${remote_url#*:}" | sed 's/\.git$//'
      ;;
    https://github.com/*.git)
      printf '%s' "${remote_url#https://github.com/}" | sed 's/\.git$//'
      ;;
    https://github.com/*)
      printf '%s' "${remote_url#https://github.com/}"
      ;;
    *)
      return 1
      ;;
  esac
}

assert_clean_tree() {
  [[ -z "$(git status --porcelain)" ]] || die "Working tree has uncommitted changes. Commit/stash them before running this updater."
}

assert_signing_identity() {
  if ! security find-identity -v -p codesigning | grep -F "\"$SIGN_IDENTITY\"" >/dev/null; then
    cat >&2 <<EOF
error: Code signing identity not found: $SIGN_IDENTITY

Create a local Code Signing certificate in Keychain Access, or pass:
  VOICEINK_SIGN_IDENTITY="Your Certificate Name" $SCRIPT_NAME

Available identities:
EOF
    security find-identity -v -p codesigning >&2 || true
    exit 1
  fi
}

sync_from_upstream() {
  log "Updating $BRANCH from $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

  git fetch "$REMOTE" "$BRANCH"
  git fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
  git checkout "$BRANCH"
  git pull --ff-only "$REMOTE" "$BRANCH"

  if ! git merge --no-edit "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
    git merge --abort >/dev/null 2>&1 || true
    die "Upstream merge failed. Resolve manually, then rerun."
  fi

  local ahead_count
  ahead_count="$(git rev-list --count "$REMOTE/$BRANCH"..HEAD)"
  if [[ "$ahead_count" != "0" ]]; then
    log "Pushing updated $BRANCH to $REMOTE"
    git push "$REMOTE" "$BRANCH"
  else
    log "$BRANCH is already up to date"
  fi
}

find_workflow_run() {
  local runs_file="$1"
  local head_sha="$2"
  local request_id="$3"

  python3 - "$runs_file" "$head_sha" "$request_id" <<'PY'
import json
import sys

path, head_sha, request_id = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as handle:
    runs = json.load(handle).get("workflow_runs", [])

for run in runs:
    title = run.get("display_title") or ""
    if run.get("head_sha") == head_sha and request_id in title:
        print(json.dumps({
            "id": run["id"],
            "status": run.get("status"),
            "conclusion": run.get("conclusion"),
            "html_url": run.get("html_url"),
        }))
        break
PY
}

json_field() {
  local json="$1"
  local field="$2"

  JSON_PAYLOAD="$json" JSON_FIELD="$field" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_PAYLOAD"])
value = payload.get(os.environ["JSON_FIELD"])
print("" if value is None else value)
PY
}

wait_for_workflow_run() {
  local repo="$1"
  local head_sha="$2"
  local request_id="$3"
  local workdir="$4"

  local deadline=$(( $(date +%s) + RUN_TIMEOUT_SECONDS ))
  local runs_file="$workdir/runs.json"
  local run_file="$workdir/run.json"
  local run_json=""
  local run_id=""
  local status=""
  local conclusion=""
  local html_url=""

  log "Waiting for GitHub Actions run $request_id"
  while [[ $(date +%s) -lt $deadline ]]; do
    github_api GET \
      "https://api.github.com/repos/$repo/actions/workflows/$WORKFLOW_FILE/runs?branch=$BRANCH&event=workflow_dispatch&per_page=20" \
      "$runs_file"

    run_json="$(find_workflow_run "$runs_file" "$head_sha" "$request_id")"
    if [[ -n "$run_json" ]]; then
      run_id="$(json_field "$run_json" id)"
      html_url="$(json_field "$run_json" html_url)"
      break
    fi

    sleep "$POLL_INTERVAL_SECONDS"
  done

  [[ -n "$run_id" ]] || die "Timed out waiting for the workflow run to appear"
  log "Tracking workflow run: $html_url"

  while [[ $(date +%s) -lt $deadline ]]; do
    github_api GET \
      "https://api.github.com/repos/$repo/actions/runs/$run_id" \
      "$run_file"

    run_json="$(cat "$run_file")"
    status="$(json_field "$run_json" status)"
    conclusion="$(json_field "$run_json" conclusion)"

    if [[ "$status" == "completed" ]]; then
      [[ "$conclusion" == "success" ]] || die "Workflow completed with conclusion: $conclusion ($html_url)"
      printf '%s' "$run_id"
      return 0
    fi

    log "Workflow status: $status"
    sleep "$POLL_INTERVAL_SECONDS"
  done

  die "Timed out waiting for workflow completion: $html_url"
}

artifact_download_url() {
  local artifacts_file="$1"
  local artifact_name="$2"

  python3 - "$artifacts_file" "$artifact_name" <<'PY'
import json
import sys

path, artifact_name = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as handle:
    artifacts = json.load(handle).get("artifacts", [])

for artifact in artifacts:
    if artifact.get("name") == artifact_name and not artifact.get("expired"):
        print(artifact.get("archive_download_url", ""))
        break
PY
}

download_artifact() {
  local repo="$1"
  local run_id="$2"
  local workdir="$3"

  local artifacts_file="$workdir/artifacts.json"
  local artifact_zip="$workdir/$ARTIFACT_NAME.zip"
  local artifact_dir="$workdir/artifact"
  local app_zip=""

  github_api GET \
    "https://api.github.com/repos/$repo/actions/runs/$run_id/artifacts" \
    "$artifacts_file"

  local download_url
  download_url="$(artifact_download_url "$artifacts_file" "$ARTIFACT_NAME")"
  [[ -n "$download_url" ]] || die "Artifact not found: $ARTIFACT_NAME"

  log "Downloading artifact $ARTIFACT_NAME"
  github_download "$download_url" "$artifact_zip"

  mkdir -p "$artifact_dir"
  unzip -q "$artifact_zip" -d "$artifact_dir"

  app_zip="$(find "$artifact_dir" -maxdepth 1 -name '*.app.zip' -type f | head -n 1)"
  [[ -n "$app_zip" ]] || die "Downloaded artifact does not contain a .app.zip file"

  mkdir -p "$workdir/app"
  unzip -q "$app_zip" -d "$workdir/app"

  local app_path="$workdir/app/VoiceInk.app"
  [[ -d "$app_path" ]] || die "Downloaded app not found at $app_path"

  printf '%s' "$app_path"
}

sign_app() {
  local app_path="$1"

  log "Signing app with identity: $SIGN_IDENTITY"
  xattr -cr "$app_path" 2>/dev/null || true
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$app_path"
  codesign --verify --deep --strict --verbose=2 "$app_path"
}

quit_existing_app() {
  log "Quitting existing VoiceInk process if it is running"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

  local deadline=$(( $(date +%s) + 15 ))
  while pgrep -x "$APP_PROCESS_NAME" >/dev/null 2>&1 && [[ $(date +%s) -lt $deadline ]]; do
    sleep 1
  done

  if pgrep -x "$APP_PROCESS_NAME" >/dev/null 2>&1; then
    pkill -TERM -x "$APP_PROCESS_NAME" >/dev/null 2>&1 || true
    sleep 2
  fi

  if pgrep -x "$APP_PROCESS_NAME" >/dev/null 2>&1; then
    die "VoiceInk is still running. Quit it manually and rerun."
  fi
}

install_app() {
  local app_path="$1"
  local backup_path=""

  [[ -d "$app_path" ]] || die "Signed app is missing: $app_path"

  quit_existing_app

  if [[ -e "$APP_DESTINATION" ]]; then
    backup_path="${APP_DESTINATION}.backup.$(date '+%Y%m%d%H%M%S')"
    log "Moving current app to $backup_path"
    mv "$APP_DESTINATION" "$backup_path"
  fi

  log "Installing signed app to $APP_DESTINATION"
  if ! ditto "$app_path" "$APP_DESTINATION"; then
    if [[ -n "$backup_path" && -d "$backup_path" && ! -e "$APP_DESTINATION" ]]; then
      mv "$backup_path" "$APP_DESTINATION" || true
    fi
    die "Install failed"
  fi

  xattr -cr "$APP_DESTINATION" 2>/dev/null || true
  codesign --verify --deep --strict --verbose=2 "$APP_DESTINATION"

  if [[ "$RELAUNCH" == "1" ]]; then
    log "Opening installed app"
    open "$APP_DESTINATION"
  fi
}

main() {
  require_command curl
  require_command unzip
  require_command ditto
  require_command codesign
  require_command security
  require_command git
  require_command python3
  require_command xattr
  require_command osascript
  require_command pgrep
  require_command pkill
  require_command find

  local root
  root="$(repo_root)" || die "Run this script inside the VoiceInk git repository"
  cd "$root"

  local repo
  repo="${VOICEINK_REPO:-$(infer_github_repo)}" || die "Could not infer GitHub repo from remote $REMOTE"

  GITHUB_API_TOKEN="$(read_token)"
  export GITHUB_API_TOKEN
  [[ -n "$GITHUB_API_TOKEN" ]] || die "GitHub token not found. Set VOICEINK_GITHUB_TOKEN/GITHUB_TOKEN or store it in Keychain service '$TOKEN_KEYCHAIN_SERVICE'."

  assert_clean_tree
  assert_signing_identity

  log "Repository: $repo"
  log "Branch: $BRANCH"
  log "Workflow: $WORKFLOW_FILE"
  log "Install destination: $APP_DESTINATION"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "Dry run complete. No GitHub workflow was started and no app was installed."
    exit 0
  fi

  if [[ "$SKIP_SYNC" != "1" ]]; then
    sync_from_upstream
  else
    log "Skipping upstream sync"
  fi

  local head_sha
  head_sha="$(git rev-parse "$BRANCH")"

  local request_id
  request_id="local-install-$(date -u '+%Y%m%dT%H%M%SZ')-${head_sha:0:12}"

  local workdir
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-update.XXXXXX")"

  if [[ "$KEEP_WORKDIR" != "1" ]]; then
    trap "rm -rf -- $(printf '%q' "$workdir")" EXIT
  else
    log "Keeping workdir: $workdir"
  fi

  local payload
  payload="$(json_escape_payload "$BRANCH" "$request_id")"

  log "Dispatching GitHub Actions build: $request_id"
  github_api POST \
    "https://api.github.com/repos/$repo/actions/workflows/$WORKFLOW_FILE/dispatches" \
    "$workdir/dispatch.json" \
    "$payload"

  local run_id
  run_id="$(wait_for_workflow_run "$repo" "$head_sha" "$request_id" "$workdir")"

  local app_path
  app_path="$(download_artifact "$repo" "$run_id" "$workdir")"
  sign_app "$app_path"

  if [[ "$SKIP_INSTALL" == "1" ]]; then
    log "Signed app is ready at $app_path"
    exit 0
  fi

  install_app "$app_path"
  log "VoiceInk update complete"
}

main "$@"
