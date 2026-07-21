#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATER_LIBRARY="$(mktemp /private/tmp/voiceink-updater-signing-library.XXXXXX)"
CODE_SIGN_ARGS="$(mktemp /private/tmp/voiceink-updater-signing-args.XXXXXX)"
TEST_APP_ROOT="$(mktemp -d /private/tmp/voiceink-updater-signing-app.XXXXXX)"
trap 'rm -f "$UPDATER_LIBRARY" "$CODE_SIGN_ARGS"; rm -rf "$TEST_APP_ROOT"' EXIT

# Load updater functions without executing main.
# shellcheck disable=SC1090
sed '$d' "$TEST_ROOT/scripts/update-build-sign-install.sh" > "$UPDATER_LIBRARY"
source "$UPDATER_LIBRARY"

xattr() { :; }
codesign() {
  printf '%s\n' "$@" >> "$CODE_SIGN_ARGS"
}

SIGN_IDENTITY='VoiceInk Local Code Signing'
sign_app "$TEST_APP_ROOT/VoiceInk.app"

if rg -Fx -- '--options' "$CODE_SIGN_ARGS" >/dev/null; then
  echo 'local signing must not enable hardened runtime for a self-signed identity' >&2
  exit 1
fi

if ! rg -Fx -- '--sign' "$CODE_SIGN_ARGS" >/dev/null || ! rg -Fx -- "$SIGN_IDENTITY" "$CODE_SIGN_ARGS" >/dev/null; then
  echo 'expected the configured local signing identity to be used' >&2
  exit 1
fi

echo 'update-build-sign-install local signing test passed'
