#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_WORKDIR="$(mktemp -d /private/tmp/voiceink-install-common.XXXXXX)"
CALLS="$TEST_WORKDIR/calls.log"
trap 'rm -rf "$TEST_WORKDIR"' EXIT

# shellcheck disable=SC1091
source "$TEST_ROOT/scripts/lib/voiceink-install-common.sh"

xattr() {
  printf 'xattr:%s\n' "$*" >> "$CALLS"
}

codesign() {
  local first_arg="${1:-}"
  local last_arg=""
  local arg

  printf 'codesign\n' >> "$CALLS"
  for arg in "$@"; do
    printf 'codesign-arg:%s\n' "$arg" >> "$CALLS"
    last_arg="$arg"
  done

  if [[ "$first_arg" == "--verify" &&
        "${FAIL_VERIFY_DESTINATION:-}" == "$last_arg" ]]; then
    return 1
  fi
}

osascript() {
  printf 'osascript\n' >> "$CALLS"
}

pgrep() {
  return 1
}

pkill() {
  printf 'pkill\n' >> "$CALLS"
}

open() {
  printf 'open:%s\n' "$1" >> "$CALLS"
}

staged_app="$TEST_WORKDIR/staged/VoiceInk.app"
mkdir -p "$staged_app"

voiceink_sign_app "$staged_app" "VoiceInk Local Code Signing"

rg -Fx -- 'codesign-arg:--sign' "$CALLS" >/dev/null
rg -Fx -- 'codesign-arg:VoiceInk Local Code Signing' "$CALLS" >/dev/null
rg -Fx -- 'codesign-arg:--strict' "$CALLS" >/dev/null

if rg -Fx -- 'codesign-arg:--options' "$CALLS" >/dev/null; then
  echo 'local signing must not enable hardened runtime' >&2
  exit 1
fi

destination="$TEST_WORKDIR/Applications/VoiceInk.app"
mkdir -p "$destination"
printf 'old\n' > "$destination/old-version"
printf 'new\n' > "$staged_app/new-version"

FAIL_VERIFY_DESTINATION="$destination"
export FAIL_VERIFY_DESTINATION

if (
  voiceink_install_app \
    "$staged_app" \
    "$destination" \
    "com.prakashjoshipax.VoiceInk" \
    "VoiceInk" \
    "1"
); then
  echo 'expected post-install verification failure' >&2
  exit 1
fi

[[ -f "$destination/old-version" ]] || {
  echo 'previous application was not restored after verification failure' >&2
  exit 1
}

[[ ! -e "$destination/new-version" ]] || {
  echo 'incomplete replacement remained after verification failure' >&2
  exit 1
}

if rg -q '^open:' "$CALLS"; then
  echo 'application must not relaunch after verification failure' >&2
  exit 1
fi

date() {
  if [[ "$*" == "+%Y%m%d%H%M%S" ]]; then
    printf '%s\n' '20260728120000'
  else
    command date "$@"
  fi
}

collision_destination="$TEST_WORKDIR/Collision/VoiceInk.app"
collision_backup="${collision_destination}.backup.20260728120000"
mkdir -p "$collision_destination" "$collision_backup"
printf 'old-collision\n' > "$collision_destination/old-version"
printf 'existing-backup\n' > "$collision_backup/existing-backup"

FAIL_VERIFY_DESTINATION="$collision_destination"
export FAIL_VERIFY_DESTINATION

if (
  voiceink_install_app \
    "$staged_app" \
    "$collision_destination" \
    "com.prakashjoshipax.VoiceInk" \
    "VoiceInk" \
    "0"
); then
  echo 'expected collision-case verification failure' >&2
  exit 1
fi

[[ -f "$collision_destination/old-version" ]] || {
  echo 'backup-name collision prevented restoration' >&2
  exit 1
}

[[ -f "$collision_backup/existing-backup" ]] || {
  echo 'installer modified a pre-existing timestamped backup' >&2
  exit 1
}

echo 'voiceink install common test passed'
