#!/usr/bin/env bash
# Installed-app end-to-end check for the inbox transcription companion.
#
# Runs against the app this workflow just built. Nothing it generates is committed or
# uploaded: the fixture audio, the downloaded model, the seeded defaults and every request
# directory are removed again on exit, and no transcript is ever printed.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLI="$ROOT/Companion/voiceink-inbox-transcribe"
APP="${VOICEINK_E2E_APP:-$HOME/Downloads/VoiceInk.app}"
DOMAIN='com.prakashjoshipax.VoiceInk'
SUPPORT="$HOME/Library/Application Support/$DOMAIN"
MODELS="$SUPPORT/WhisperModels"
RECORDINGS="$SUPPORT/Recordings"
STORE="$SUPPORT/default.store"
ANCHOR="$HOME/Library/Application Support/VoiceInk/InboxCompanion"
ANCHOR_PROMPT="$ANCHOR/inbox-transcription-prompt.txt"
MODEL_NAME='ggml-tiny'
MODEL_FILE="$MODELS/$MODEL_NAME.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME.bin"
MODE_KEY='modeConfigurationsV2'
REQUEST_TIMEOUT=600

WORK="$(mktemp -d "${TMPDIR:-/tmp}/voiceink-inbox-e2e.XXXXXX")"
MODEL_WAS_PRESENT=0
PROMPT_BACKUP=''
DEFAULTS_BACKUP="$WORK/defaults-backup.plist"
HAD_MODE_KEY=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equal() {
  [[ "$2" == "$1" ]] || fail "$3 (expected '$1', got '$2')"
}

quit_app() {
  /usr/bin/osascript -e 'tell application id "com.prakashjoshipax.VoiceInk" to quit' >/dev/null 2>&1 || true
  /usr/bin/pkill -x VoiceInk >/dev/null 2>&1 || true
  # cfprefsd caches this domain for the app; drop it so a reseed is observed on next launch.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    /usr/bin/pgrep -x VoiceInk >/dev/null 2>&1 || break
    /bin/sleep 1
  done
}

cleanup() {
  quit_app
  if [[ "$MODEL_WAS_PRESENT" -eq 0 ]]; then
    rm -f "$MODEL_FILE"
  fi
  if [[ -n "$PROMPT_BACKUP" && -f "$PROMPT_BACKUP" ]]; then
    cat "$PROMPT_BACKUP" > "$ANCHOR_PROMPT" 2>/dev/null || true
    chmod 0600 "$ANCHOR_PROMPT" 2>/dev/null || true
  fi
  if [[ "$HAD_MODE_KEY" -eq 1 && -f "$DEFAULTS_BACKUP" ]]; then
    /usr/bin/defaults import "$DOMAIN" "$DEFAULTS_BACKUP" >/dev/null 2>&1 || true
  else
    /usr/bin/defaults delete "$DOMAIN" "$MODE_KEY" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
  rm -rf "${TMPDIR:-/tmp}/voiceink-inbox-companion"
}
trap cleanup EXIT

json_field() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
for key in sys.argv[2].split("."):
    document = document[key]
# Booleans print as JSON so assertions read `true`/`false` rather than Python spelling.
print("" if document is None else document if isinstance(document, str) else json.dumps(document))
PY
}

history_count() {
  if [[ ! -f "$STORE" ]]; then
    printf '0'
    return
  fi
  /usr/bin/sqlite3 -readonly "$STORE" 'SELECT COUNT(*) FROM ZTRANSCRIPTION;' 2>/dev/null || printf 'unreadable'
}

recordings_listing() {
  if [[ -d "$RECORDINGS" ]]; then
    /bin/ls -1 "$RECORDINGS" | /usr/bin/sort
  fi
}

settings_digest() {
  /usr/bin/defaults export "$DOMAIN" - 2>/dev/null | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

mode_digest() {
  /usr/bin/defaults read "$DOMAIN" "$MODE_KEY" 2>/dev/null | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

seed_modes() {
  local duplicate="$1"
  local hex

  hex="$(/usr/bin/python3 - "$duplicate" "$MODEL_NAME" <<'PY'
import json
import sys
import uuid

duplicate = sys.argv[1] == "duplicate"
model = sys.argv[2]


def mode(identifier):
    return {
        "id": identifier,
        "name": "Inbox",
        "isAIEnhancementEnabled": False,
        "selectedTranscriptionModelName": model,
        "selectedLanguage": "ru",
        "isTextFormattingEnabled": False,
        "isRealtimeTranscriptionEnabled": False,
        "isEnabled": True,
        "isDefault": False,
        "useClipboardContext": False,
        "useSelectedTextContext": False,
        "useScreenCapture": False,
    }


modes = [mode(str(uuid.uuid4()))]
if duplicate:
    modes.append(mode(str(uuid.uuid4())))
print(json.dumps(modes, ensure_ascii=False).encode("utf-8").hex())
PY
)"
  /usr/bin/defaults write "$DOMAIN" "$MODE_KEY" -data "$hex"
}

assert_success_response() {
  local response="$1"
  local label="$2"

  assert_equal '1' "$(json_field "$response" contractVersion)" "$label contract version"
  assert_equal 'success' "$(json_field "$response" status)" "$label status"
  assert_equal 'Inbox' "$(json_field "$response" result.mode.name)" "$label mode name"
  assert_equal 'whisper' "$(json_field "$response" result.model.provider)" "$label provider"
  assert_equal 'ru' "$(json_field "$response" result.language)" "$label language"
  assert_equal 'local' "$(json_field "$response" result.execution)" "$label execution"
  assert_equal 'true' "$(json_field "$response" result.prompt.applied)" "$label prompt applied"
  assert_equal 'false' "$(json_field "$response" result.aiEnhancementApplied)" "$label AI enhancement"
  [[ -n "$(json_field "$response" result.transcript)" ]] || fail "$label transcript was empty"
}

run_request() {
  local output="$1"
  shift

  VOICEINK_COMPANION_APP="$APP" "$CLI" --timeout "$REQUEST_TIMEOUT" "$@" > "$output" 2> "$WORK/stderr.txt"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

[[ -d "$APP" ]] || fail "installed app not found at $APP"
[[ -x "$CLI" ]] || fail "companion CLI not found at $CLI"
command -v /usr/bin/sqlite3 >/dev/null || fail "sqlite3 is required to count history rows"

quit_app

if /usr/bin/defaults read "$DOMAIN" "$MODE_KEY" >/dev/null 2>&1; then
  HAD_MODE_KEY=1
  /usr/bin/defaults export "$DOMAIN" "$DEFAULTS_BACKUP"
fi

if [[ -f "$ANCHOR_PROMPT" ]]; then
  PROMPT_BACKUP="$WORK/prompt-backup.txt"
  cat "$ANCHOR_PROMPT" > "$PROMPT_BACKUP"
fi

# ---------------------------------------------------------------------------
# Fixture audio, generated locally and never committed or uploaded
# ---------------------------------------------------------------------------

FIXTURE="$WORK/fixture.m4a"
RUSSIAN_VOICE="$(/usr/bin/say -v '?' | /usr/bin/awk '/ru_RU/ {print $1; exit}')"
if [[ -n "$RUSSIAN_VOICE" ]]; then
  /usr/bin/say -v "$RUSSIAN_VOICE" -o "$WORK/fixture.aiff" 'Привет. Это короткая тестовая заметка для базы знаний.'
else
  # No Russian voice on this runner; the assertions cover response metadata, not wording.
  /usr/bin/say -o "$WORK/fixture.aiff" 'Privet. Eto korotkaya testovaya zametka dlya bazy znaniy.'
fi
/usr/bin/afconvert -f m4af -d aac "$WORK/fixture.aiff" "$FIXTURE"
[[ -s "$FIXTURE" ]] || fail "fixture audio was not generated"
FIXTURE_CHECKSUM="$(/usr/bin/shasum -a 256 "$FIXTURE" | /usr/bin/awk '{print $1}')"

# ---------------------------------------------------------------------------
# Model and mode setup
# ---------------------------------------------------------------------------

mkdir -p "$MODELS"
if [[ -f "$MODEL_FILE" ]]; then
  MODEL_WAS_PRESENT=1
else
  /usr/bin/curl -fsSL --retry 3 -o "$MODEL_FILE" "$MODEL_URL" || fail "could not download $MODEL_NAME"
fi
[[ -s "$MODEL_FILE" ]] || fail "$MODEL_NAME is empty"

seed_modes single
SEEDED_MODE_DIGEST="$(mode_digest)"
HISTORY_BEFORE="$(history_count)"
RECORDINGS_BEFORE="$(recordings_listing)"

# ---------------------------------------------------------------------------
# Request 1: cold start through the companion URL with the app closed
# ---------------------------------------------------------------------------

/usr/bin/pgrep -x VoiceInk >/dev/null 2>&1 && fail "app was still running before the cold-start request"
run_request "$WORK/response1.json" "$FIXTURE" || fail "cold-start request failed: $(cat "$WORK/response1.json")"
assert_success_response "$WORK/response1.json" 'cold start'

assert_equal "$FIXTURE_CHECKSUM" "$(/usr/bin/shasum -a 256 "$FIXTURE" | /usr/bin/awk '{print $1}')" 'cold start input checksum'
assert_equal "$SEEDED_MODE_DIGEST" "$(mode_digest)" 'cold start mode settings'
assert_equal "$HISTORY_BEFORE" "$(history_count)" 'cold start history count'
assert_equal "$RECORDINGS_BEFORE" "$(recordings_listing)" 'cold start recordings listing'

# Taken once the app is warm, so the comparison isolates the request from launch-time writes.
SETTINGS_DIGEST="$(settings_digest)"

# ---------------------------------------------------------------------------
# Request 2: second request while the app is already running
# ---------------------------------------------------------------------------

/usr/bin/pgrep -x VoiceInk >/dev/null 2>&1 || fail "app was not running for the warm request"
run_request "$WORK/response2.json" "$FIXTURE" || fail "warm request failed: $(cat "$WORK/response2.json")"
assert_success_response "$WORK/response2.json" 'warm'

[[ "$(json_field "$WORK/response1.json" requestId)" != "$(json_field "$WORK/response2.json" requestId)" ]] \
  || fail 'both requests reported the same request ID'
assert_equal "$FIXTURE_CHECKSUM" "$(/usr/bin/shasum -a 256 "$FIXTURE" | /usr/bin/awk '{print $1}')" 'warm input checksum'
assert_equal "$SETTINGS_DIGEST" "$(settings_digest)" 'warm settings snapshot'
assert_equal "$SEEDED_MODE_DIGEST" "$(mode_digest)" 'warm mode settings'
assert_equal "$HISTORY_BEFORE" "$(history_count)" 'warm history count'
assert_equal "$RECORDINGS_BEFORE" "$(recordings_listing)" 'warm recordings listing'

# ---------------------------------------------------------------------------
# Failure paths, none of which may reach a provider
# ---------------------------------------------------------------------------

printf '\377' > "$ANCHOR_PROMPT"
if run_request "$WORK/response-prompt.json" "$FIXTURE"; then
  fail 'invalid prompt request unexpectedly succeeded'
fi
assert_equal 'failure' "$(json_field "$WORK/response-prompt.json" status)" 'invalid prompt status'
assert_equal 'prompt_invalid_utf8' "$(json_field "$WORK/response-prompt.json" error.code)" 'invalid prompt code'

if [[ -n "$PROMPT_BACKUP" ]]; then
  cat "$PROMPT_BACKUP" > "$ANCHOR_PROMPT"
else
  cat "$ROOT/Companion/inbox-transcription-prompt.txt" > "$ANCHOR_PROMPT"
fi
chmod 0600 "$ANCHOR_PROMPT"

quit_app
seed_modes duplicate
if run_request "$WORK/response-duplicate.json" "$FIXTURE"; then
  fail 'duplicate Inbox mode request unexpectedly succeeded'
fi
assert_equal 'failure' "$(json_field "$WORK/response-duplicate.json" status)" 'duplicate mode status'
assert_equal 'inbox_mode_duplicate' "$(json_field "$WORK/response-duplicate.json" error.code)" 'duplicate mode code'

assert_equal "$HISTORY_BEFORE" "$(history_count)" 'failure path history count'
assert_equal "$RECORDINGS_BEFORE" "$(recordings_listing)" 'failure path recordings listing'

echo 'inbox companion installed-app E2E passed'
