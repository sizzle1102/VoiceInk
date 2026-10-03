#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_WORKDIR="$(mktemp -d /private/tmp/voiceink-installer-failure.XXXXXX)"
trap 'rm -rf "$TEST_WORKDIR"' EXIT

run_update_failure() (
  source "$TEST_ROOT/scripts/update-build-sign-install.sh"
  SKIP_SYNC=1
  voiceink_dispatch_workflow() { [[ "$FAILURE_STAGE" != dispatch ]]; }
  voiceink_wait_for_workflow_run() { printf 'fixture-run'; }
  voiceink_remote_branch_sha() { printf 'fixture-sha'; }
  voiceink_download_run_artifact_zip() {
    [[ "$FAILURE_STAGE" != download ]] || return 1
    printf 'new artifact\n' > "$4"
  }
  voiceink_extract_artifact_zip() {
    [[ "$FAILURE_STAGE" != extract ]] || return 1
    printf '%s' "$TEST_WORKDIR/VoiceInk.app"
  }
  xattr() { [[ "$FAILURE_STAGE" != xattr ]]; }
  codesign() {
    [[ "$FAILURE_STAGE" != sign || "$1" != --force ]] || return 1
    [[ "$FAILURE_STAGE" != verify || "$1" != --verify ]] || return 1
  }
  voiceink_install_app() { touch "$TEST_WORKDIR/installed-$FAILURE_STAGE"; }
  run_remote_update 'fixture/repo' "$TEST_WORKDIR" "$TEST_WORKDIR/cache.zip"
)

for stage in dispatch download extract xattr sign verify; do
  printf 'old artifact\n' > "$TEST_WORKDIR/cache.zip"
  if FAILURE_STAGE="$stage" run_update_failure; then
    echo "updater continued after $stage failed" >&2
    exit 1
  fi
  [[ ! -e "$TEST_WORKDIR/installed-$stage" ]] || {
    echo "failed $stage allowed installation" >&2
    exit 1
  }
done

if (
  source "$TEST_ROOT/scripts/install-app.sh"
  voiceink_extract_artifact_zip() { printf '%s' "$TEST_WORKDIR/VoiceInk.app"; }
  xattr() { :; }
  codesign() { [[ "$1" != --force ]]; }
  voiceink_install_app() { touch "$TEST_WORKDIR/archive-installed"; }
  install_archive "$TEST_WORKDIR/cache.zip" "$TEST_WORKDIR"
); then
  echo 'ZIP installer continued after signing failed' >&2
  exit 1
fi
[[ ! -e "$TEST_WORKDIR/archive-installed" ]]

if (
  source "$TEST_ROOT/scripts/install-app.sh"
  voiceink_read_token() { printf 'fixture-token'; }
  voiceink_infer_github_repo() { printf 'fixture/repo'; }
  voiceink_find_latest_available_artifact() { printf '123\tfixture-sha\thttps://fixture.invalid/artifact\n'; }
  voiceink_download_artifact_zip() { return 1; }
  install_archive() { touch "$TEST_WORKDIR/stale-installed"; }
  install_latest_archive "$TEST_WORKDIR"
); then
  echo 'latest installer used a stale cache after download failed' >&2
  exit 1
fi
[[ ! -e "$TEST_WORKDIR/stale-installed" ]]

mkdir -p "$TEST_WORKDIR/original.app" "$TEST_WORKDIR/staged.app"
printf 'original\n' > "$TEST_WORKDIR/original.app/version"
if (
  source "$TEST_ROOT/scripts/lib/voiceink-install-common.sh"
  voiceink_quit_existing_app() { :; }
  mv() { return 1; }
  ditto() { touch "$TEST_WORKDIR/copy-attempted"; }
  codesign() { return 1; }
  voiceink_install_app "$TEST_WORKDIR/staged.app" "$TEST_WORKDIR/original.app" 'fixture.bundle' 'Fixture' 0
); then
  echo 'installation continued after backup move failed' >&2
  exit 1
fi
[[ ! -e "$TEST_WORKDIR/copy-attempted" ]]
[[ "$(cat "$TEST_WORKDIR/original.app/version")" == original ]]
echo 'installer failure propagation tests passed'
