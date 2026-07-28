#!/usr/bin/env bash

voiceink_log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

voiceink_die() {
  echo "error: $*" >&2
  return 1
}

voiceink_require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    voiceink_die "Missing required command: $1"
}

voiceink_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

voiceink_read_token() {
  local keychain_service="$1"
  local keychain_account="$2"

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
    -a "$keychain_account" \
    -s "$keychain_service" \
    -w 2>/dev/null || true
}

voiceink_infer_github_repo() {
  local remote="$1"
  local remote_url
  remote_url="$(git config --get "remote.${remote}.url")"

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

voiceink_github_api() {
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

voiceink_github_download() {
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

voiceink_dispatch_workflow() {
  local repo="$1"
  local workflow="$2"
  local ref="$3"
  local request_id="$4"
  local inputs_json="$5"
  local output="$6"
  local payload

  payload="$(
    REF="$ref" REQUEST_ID="$request_id" INPUTS_JSON="$inputs_json" \
      python3 - <<'PY'
import json
import os

inputs = json.loads(os.environ["INPUTS_JSON"])
inputs["request_id"] = os.environ["REQUEST_ID"]
print(json.dumps({
    "ref": os.environ["REF"],
    "inputs": inputs,
}))
PY
  )"

  voiceink_github_api POST \
    "https://api.github.com/repos/$repo/actions/workflows/$workflow/dispatches" \
    "$output" \
    "$payload"
}

voiceink_find_workflow_run() {
  local runs_file="$1"
  local request_id="$2"

  python3 - "$runs_file" "$request_id" <<'PY'
import json
import sys

path, request_id = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as handle:
    runs = json.load(handle).get("workflow_runs", [])

for run in runs:
    title = run.get("display_title") or ""
    if request_id in title:
        print(json.dumps({
            "id": run["id"],
            "head_sha": run.get("head_sha") or "",
            "status": run.get("status") or "",
            "conclusion": run.get("conclusion"),
            "html_url": run.get("html_url") or "",
        }))
        break
PY
}

voiceink_json_field() {
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

voiceink_wait_for_workflow_run() {
  local repo="$1"
  local workflow="$2"
  local branch="$3"
  local request_id="$4"
  local expected_sha="$5"
  local workdir="$6"
  local timeout_seconds="${VOICEINK_RUN_TIMEOUT_SECONDS:-3600}"
  local poll_seconds="${VOICEINK_POLL_INTERVAL_SECONDS:-15}"
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local runs_file="$workdir/${workflow}.runs.json"
  local run_file="$workdir/${workflow}.run.json"
  local run_json=""
  local run_id=""
  local head_sha=""
  local status=""
  local conclusion=""
  local html_url=""

  mkdir -p "$workdir"
  voiceink_log "Waiting for $workflow run $request_id"
  while [[ $(date +%s) -lt $deadline ]]; do
    voiceink_github_api GET \
      "https://api.github.com/repos/$repo/actions/workflows/$workflow/runs?branch=$branch&event=workflow_dispatch&per_page=30" \
      "$runs_file"

    run_json="$(voiceink_find_workflow_run "$runs_file" "$request_id")"
    if [[ -n "$run_json" ]]; then
      run_id="$(voiceink_json_field "$run_json" id)"
      head_sha="$(voiceink_json_field "$run_json" head_sha)"
      html_url="$(voiceink_json_field "$run_json" html_url)"
      if [[ -n "$expected_sha" && "$head_sha" != "$expected_sha" ]]; then
        voiceink_die \
          "$workflow run $run_id built $head_sha instead of $expected_sha"
        return 1
      fi
      break
    fi

    sleep "$poll_seconds"
  done

  [[ -n "$run_id" ]] ||
    voiceink_die "Timed out waiting for $workflow run to appear" || return 1
  voiceink_log "Tracking workflow run: $html_url"

  while [[ $(date +%s) -lt $deadline ]]; do
    voiceink_github_api GET \
      "https://api.github.com/repos/$repo/actions/runs/$run_id" \
      "$run_file"
    run_json="$(cat "$run_file")"
    status="$(voiceink_json_field "$run_json" status)"
    conclusion="$(voiceink_json_field "$run_json" conclusion)"

    if [[ "$status" == "completed" ]]; then
      [[ "$conclusion" == "success" ]] ||
        voiceink_die \
          "$workflow completed with conclusion: $conclusion ($html_url)" ||
        return 1
      printf '%s' "$run_id"
      return 0
    fi

    voiceink_log "$workflow status: $status"
    sleep "$poll_seconds"
  done

  voiceink_die "Timed out waiting for workflow completion: $html_url"
}

voiceink_remote_branch_sha() {
  local repo="$1"
  local branch="$2"
  local workdir="$3"
  local ref_file="$workdir/ref-${branch//\//-}.json"

  mkdir -p "$workdir"
  voiceink_github_api GET \
    "https://api.github.com/repos/$repo/git/ref/heads/$branch" \
    "$ref_file"
  python3 - "$ref_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
print(payload["object"]["sha"])
PY
}

voiceink_assert_signing_identity() {
  local sign_identity="$1"

  if security find-identity -v -p codesigning |
    grep -F "\"$sign_identity\"" >/dev/null; then
    return 0
  fi

  cat >&2 <<EOF
error: Code signing identity not found: $sign_identity

Create a local Code Signing certificate in Keychain Access, or set:
  VOICEINK_SIGN_IDENTITY="Your Certificate Name"

Available identities:
EOF
  security find-identity -v -p codesigning >&2 || true
  return 1
}

voiceink_artifact_download_url() {
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

voiceink_find_latest_available_artifact() {
  local repo="$1"
  local workflow="$2"
  local branch="$3"
  local artifact_name="$4"
  local workdir="$5"
  local runs_file="$workdir/runs.json"
  local artifacts_file=""
  local run_id=""
  local head_sha=""
  local download_url=""

  mkdir -p "$workdir"
  voiceink_github_api GET \
    "https://api.github.com/repos/$repo/actions/workflows/$workflow/runs?branch=$branch&status=success&per_page=30" \
    "$runs_file"

  while IFS=$'\t' read -r run_id head_sha; do
    [[ -n "$run_id" ]] || continue
    artifacts_file="$workdir/artifacts-$run_id.json"
    voiceink_github_api GET \
      "https://api.github.com/repos/$repo/actions/runs/$run_id/artifacts" \
      "$artifacts_file"
    download_url="$(
      voiceink_artifact_download_url "$artifacts_file" "$artifact_name"
    )"
    if [[ -n "$download_url" ]]; then
      printf '%s\t%s\t%s\n' "$run_id" "$head_sha" "$download_url"
      return 0
    fi
  done < <(
    python3 - "$runs_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    runs = json.load(handle).get("workflow_runs", [])

for run in runs:
    if run.get("status") == "completed" and run.get("conclusion") == "success":
        print(f"{run['id']}\t{run.get('head_sha', '')}")
PY
  )

  voiceink_die \
    "No non-expired $artifact_name artifact found for $workflow on $branch"
}

voiceink_download_artifact_zip() {
  local download_url="$1"
  local destination="$2"
  local destination_dir
  local temporary_path

  destination_dir="$(dirname "$destination")"
  temporary_path="$destination.download.$$"
  mkdir -p "$destination_dir"
  rm -f -- "$temporary_path"

  if ! voiceink_github_download "$download_url" "$temporary_path"; then
    rm -f -- "$temporary_path"
    voiceink_die "Artifact download failed"
    return 1
  fi

  mv "$temporary_path" "$destination"
}

voiceink_download_run_artifact_zip() {
  local repo="$1"
  local run_id="$2"
  local artifact_name="$3"
  local destination="$4"
  local workdir="$5"
  local artifacts_file="$workdir/run-$run_id-artifacts.json"
  local download_url

  mkdir -p "$workdir"
  voiceink_github_api GET \
    "https://api.github.com/repos/$repo/actions/runs/$run_id/artifacts" \
    "$artifacts_file"
  download_url="$(
    voiceink_artifact_download_url "$artifacts_file" "$artifact_name"
  )"
  [[ -n "$download_url" ]] ||
    voiceink_die "Artifact not found: $artifact_name" || return 1

  voiceink_download_artifact_zip "$download_url" "$destination"
}

voiceink_extract_artifact_zip() {
  local archive_path="$1"
  local workdir="$2"
  local bundle_id="$3"
  local artifact_dir="$workdir/artifact"
  local app_dir="$workdir/app"
  local app_zip=""
  local app_path="$app_dir/VoiceInk.app"
  local actual_bundle_id=""
  local app_zips=()
  local candidate=""

  [[ -f "$archive_path" ]] ||
    voiceink_die "Artifact ZIP not found: $archive_path" || return 1

  mkdir -p "$artifact_dir" "$app_dir"
  unzip -q "$archive_path" -d "$artifact_dir"

  while IFS= read -r candidate; do
    app_zips+=("$candidate")
  done < <(find "$artifact_dir" -maxdepth 1 -name '*.app.zip' -type f)

  [[ "${#app_zips[@]}" -eq 1 ]] ||
    voiceink_die "Artifact must contain exactly one top-level .app.zip file" ||
    return 1

  app_zip="${app_zips[0]}"
  unzip -q "$app_zip" -d "$app_dir"

  [[ -d "$app_path" ]] ||
    voiceink_die "Downloaded app not found at $app_path" || return 1
  [[ -f "$app_path/Contents/Info.plist" ]] ||
    voiceink_die "Downloaded app has no Info.plist" || return 1

  actual_bundle_id="$(
    plutil -extract CFBundleIdentifier raw -o - \
      "$app_path/Contents/Info.plist"
  )"
  [[ "$actual_bundle_id" == "$bundle_id" ]] ||
    voiceink_die "Unexpected bundle identifier: $actual_bundle_id" || return 1

  printf '%s' "$app_path"
}

voiceink_sign_app() {
  local app_path="$1"
  local sign_identity="$2"

  voiceink_log "Signing app with identity: $sign_identity"
  xattr -cr "$app_path"
  codesign --force --deep --sign "$sign_identity" "$app_path"
  codesign --verify --deep --strict --verbose=2 "$app_path"
}

voiceink_quit_existing_app() {
  local bundle_id="$1"
  local process_name="$2"
  local deadline

  voiceink_log "Quitting existing $process_name process if it is running"
  osascript -e "tell application id \"$bundle_id\" to quit" \
    >/dev/null 2>&1 || true

  deadline=$(( $(date +%s) + 15 ))
  while pgrep -x "$process_name" >/dev/null 2>&1 &&
    [[ $(date +%s) -lt $deadline ]]; do
    sleep 1
  done

  if pgrep -x "$process_name" >/dev/null 2>&1; then
    pkill -TERM -x "$process_name" >/dev/null 2>&1 || true
    sleep 2
  fi

  if pgrep -x "$process_name" >/dev/null 2>&1; then
    voiceink_die "$process_name is still running. Quit it manually and rerun."
    return 1
  fi
}

voiceink_install_app() {
  local app_path="$1"
  local destination="$2"
  local bundle_id="$3"
  local process_name="$4"
  local relaunch="$5"
  local backup_path=""
  local install_failed=0

  [[ -d "$app_path" ]] ||
    voiceink_die "Signed app is missing: $app_path" || return 1
  [[ "$destination" == /*.app ]] ||
    voiceink_die "Application destination must be an absolute .app path" ||
    return 1

  voiceink_quit_existing_app "$bundle_id" "$process_name" || return 1

  if [[ -e "$destination" ]]; then
    backup_path="${destination}.backup.$(date '+%Y%m%d%H%M%S')"
    voiceink_log "Moving current app to $backup_path"
    mv "$destination" "$backup_path"
  fi

  voiceink_log "Installing signed app to $destination"
  ditto "$app_path" "$destination" || install_failed=1
  if [[ "$install_failed" == "0" ]]; then
    xattr -cr "$destination" || install_failed=1
  fi
  if [[ "$install_failed" == "0" ]]; then
    codesign --verify --deep --strict --verbose=2 "$destination" ||
      install_failed=1
  fi

  if [[ "$install_failed" != "0" ]]; then
    if [[ -e "$destination" ]]; then
      rm -rf -- "$destination"
    fi
    if [[ -n "$backup_path" && -d "$backup_path" ]]; then
      mv "$backup_path" "$destination" || true
    fi
    voiceink_die "Install failed; previous application was restored"
    return 1
  fi

  if [[ "$relaunch" == "1" ]]; then
    voiceink_log "Opening installed app"
    if ! open "$destination"; then
      voiceink_die "Application installed but could not be relaunched"
      return 1
    fi
  fi
}
