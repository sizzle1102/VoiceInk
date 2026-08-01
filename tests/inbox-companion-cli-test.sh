#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI_SOURCE="$ROOT/Companion/voiceink-inbox-transcribe"
PROMPT_SOURCE="$ROOT/Companion/inbox-transcription-prompt.txt"
TEST_ROOT="$(mktemp -d /private/tmp/voiceink-inbox-companion.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

json_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1"
}

require_cli() {
  [[ -x "$CLI_SOURCE" ]] || fail "missing executable CLI: $CLI_SOURCE"
  [[ -f "$PROMPT_SOURCE" ]] || fail "missing companion prompt: $PROMPT_SOURCE"
}

prepare_case() {
  CASE_DIR="$(mktemp -d "$TEST_ROOT/case.XXXXXX")"
  mkdir -p "$CASE_DIR/Companion" "$CASE_DIR/bin" "$CASE_DIR/tmp" "$CASE_DIR/home"
  cp "$CLI_SOURCE" "$CASE_DIR/Companion/voiceink-inbox-transcribe"
  cp "$PROMPT_SOURCE" "$CASE_DIR/Companion/inbox-transcription-prompt.txt"
  chmod +x "$CASE_DIR/Companion/voiceink-inbox-transcribe"
  # The bridge only trusts this fixed anchor, so every case runs under an isolated HOME.
  CASE_HOME="$CASE_DIR/home"
  ANCHOR_DIR="$CASE_HOME/Library/Application Support/VoiceInk/InboxCompanion"
  ANCHOR_PROMPT="$ANCHOR_DIR/inbox-transcription-prompt.txt"
  ANCHOR_CLI="$ANCHOR_DIR/voiceink-inbox-transcribe"
  INPUT_PATH="$CASE_DIR/input.m4a"
  printf 'audio bytes must stay outside the open invocation\n' > "$INPUT_PATH"
  FAKE_OPEN_LOG="$CASE_DIR/open.log"

  cat > "$CASE_DIR/bin/fake-open" <<'FAKE_OPEN'
#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 4 ]] || { echo "fake open received an unexpected argument count" >&2; exit 1; }
[[ "$1" == "-gj" && "$2" == "-a" && "$3" == "VoiceInk" ]] || {
  echo "fake open received unexpected launch arguments" >&2
  exit 1
}

printf '%s\n' "$*" > "$VOICEINK_FAKE_OPEN_LOG"

request_path="$(/usr/bin/python3 - "$4" <<'PY'
import sys
import urllib.parse

query = urllib.parse.parse_qs(urllib.parse.urlsplit(sys.argv[1]).query, keep_blank_values=True)
print(query["request"][0])
PY
)"
cancellation_path="$(/usr/bin/plutil -extract cancellationPath raw -o - "$request_path")"

case "${VOICEINK_FAKE_OPEN_MODE:-success}" in
  timeout)
    # Preserve the CLI's zero-byte marker beyond its request-directory cleanup.
    ln -s "$VOICEINK_FAKE_CANCEL_OBSERVED" "$cancellation_path"
    exit 0
    ;;
  app-failure)
    response_path="$(/usr/bin/plutil -extract responsePath raw -o - "$request_path")"
    request_id="$(/usr/bin/plutil -extract requestId raw -o - "$request_path")"
    /usr/bin/python3 - "$response_path" "$request_id" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as response_file:
    json.dump({
        "contractVersion": 1,
        "requestId": sys.argv[2],
        "status": "failure",
        "result": None,
        "error": {
            "code": "inbox_mode_duplicate",
            "phase": "preflight",
            "message": "Inbox companion request failed.",
            "retryable": False,
        },
    }, response_file)
PY
    exit 0
    ;;
  success)
    ;;
  *)
    echo "unknown fake open mode: $VOICEINK_FAKE_OPEN_MODE" >&2
    exit 1
    ;;
esac

/usr/bin/python3 - "$4" <<'PY'
import json
import os
import sys
import urllib.parse

url = urllib.parse.urlsplit(sys.argv[1])
if url.scheme != "voiceink-inbox" or url.netloc != "transcribe":
    raise SystemExit("unexpected invocation URL")

query = urllib.parse.parse_qs(url.query, keep_blank_values=True)
if set(query) != {"request"} or len(query["request"]) != 1:
    raise SystemExit("invocation URL must contain exactly one request query item")

request_path = query["request"][0]
if not os.path.isabs(request_path):
    raise SystemExit("request path must be absolute")

with open(request_path, encoding="utf-8") as request_file:
    request = json.load(request_file)

expected_keys = {
    "contractVersion",
    "requestId",
    "inputPath",
    "promptPath",
    "responsePath",
    "cancellationPath",
    "timeoutSeconds",
}
if set(request) != expected_keys:
    raise SystemExit("request contains fields outside the contract")
if request["contractVersion"] != 1:
    raise SystemExit("unexpected request contract version")
if request["inputPath"] != os.environ["VOICEINK_FAKE_EXPECTED_INPUT"]:
    raise SystemExit("request input path changed")
if request["promptPath"] != os.environ["VOICEINK_FAKE_EXPECTED_PROMPT"]:
    raise SystemExit("request prompt path changed")
if not request["responsePath"].endswith("/response.json"):
    raise SystemExit("unexpected response path")
if not request["cancellationPath"].endswith("/cancel"):
    raise SystemExit("unexpected cancellation path")

observed_prompt = os.environ.get("VOICEINK_FAKE_PROMPT_OBSERVED")
if observed_prompt:
    with open(observed_prompt, "w", encoding="utf-8") as observed_file:
        observed_file.write(request["promptPath"])

response = {
    "contractVersion": 1,
    "requestId": request["requestId"],
    "status": "success",
    "result": {
        "transcript": "fixed transcript",
        "mode": {"id": "00000000-0000-4000-8000-000000000001", "name": "Inbox"},
        "model": {"name": "whisper-large-v3", "displayName": "Whisper Large v3", "provider": "local"},
        "language": "ru",
        "mediaDurationSeconds": 1.25,
        "execution": "local",
        "prompt": {"applied": True, "sha256": "fixed-sha256"},
        "aiEnhancementApplied": False,
    },
    "error": None,
}
with open(request["responsePath"], "w", encoding="utf-8") as response_file:
    json.dump(response, response_file, ensure_ascii=False, separators=(",", ":"))
    response_file.write("\n")
PY
FAKE_OPEN
  chmod +x "$CASE_DIR/bin/fake-open"

  cat > "$CASE_DIR/bin/failing-open" <<'FAILING_OPEN'
#!/usr/bin/env bash
echo 'launch diagnostic that must not reach CLI stderr' >&2
exit 42
FAILING_OPEN
  chmod +x "$CASE_DIR/bin/failing-open"
}

run_cli() {
  local stdout_path="$1"
  local stderr_path="$2"
  shift 2
  local open_command="${VOICEINK_TEST_OPEN_COMMAND:-$CASE_DIR/bin/fake-open}"

  local cli="${VOICEINK_TEST_CLI:-$CASE_DIR/Companion/voiceink-inbox-transcribe}"

  HOME="$CASE_HOME" \
    TMPDIR="${VOICEINK_TEST_TMPDIR:-$CASE_DIR/tmp}" \
    VOICEINK_COMPANION_OPEN_COMMAND="$open_command" \
    VOICEINK_FAKE_OPEN_LOG="$FAKE_OPEN_LOG" \
    VOICEINK_FAKE_CANCEL_OBSERVED="$CASE_DIR/cancel-observed.txt" \
    VOICEINK_FAKE_EXPECTED_INPUT="$INPUT_PATH" \
    VOICEINK_FAKE_EXPECTED_PROMPT="$ANCHOR_PROMPT" \
    VOICEINK_FAKE_PROMPT_OBSERVED="$CASE_DIR/prompt-observed.txt" \
    "$cli" "$@" > "$stdout_path" 2> "$stderr_path"
}

run_cli_expecting_success() {
  local stdout_path="$1"
  local stderr_path="$2"

  # Without this, `set -e` aborts the whole suite with no diagnostic at all.
  if ! run_cli "$@"; then
    fail "invocation failed unexpectedly (stdout: $(cat "$stdout_path" 2>/dev/null), stderr: $(cat "$stderr_path" 2>/dev/null))"
  fi
}

file_mode() {
  /usr/bin/stat -f '%Lp' "$1"
}

assert_failure_code() {
  local output="$1"
  local expected_code="$2"

  assert_equal "failure" "$(json_value "$output" status)" "failure status"
  assert_equal "$expected_code" "$(json_value "$output" error.code)" "failure code"
  assert_equal "1" "$(json_value "$output" contractVersion)" "failure contract version"
}

assert_response_has_uuid_request_id() {
  local output="$1"

  /usr/bin/python3 - "$output" >/dev/null 2>&1 <<'PY' || fail "response did not decode with a UUID request ID"
import json
import sys
import uuid

with open(sys.argv[1], encoding="utf-8") as response_file:
    response = json.load(response_file)

uuid.UUID(response["requestId"])
PY
}

run_success_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"

  run_cli_expecting_success "$stdout_path" "$stderr_path" "$INPUT_PATH"

  [[ ! -s "$stderr_path" ]] || fail "success case wrote stderr"
  assert_equal "success" "$(json_value "$stdout_path" status)" "success status"
  assert_equal "fixed transcript" "$(json_value "$stdout_path" result.transcript)" "success transcript"
  [[ -s "$FAKE_OPEN_LOG" ]] || fail "success case did not invoke fake open"
  echo 'PASS: success'
}

run_missing_input_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"

  if run_cli "$stdout_path" "$stderr_path" "$CASE_DIR/missing.m4a"; then
    fail "missing input invocation unexpectedly succeeded"
  fi

  assert_failure_code "$stdout_path" "input_missing"
  [[ ! -e "$FAKE_OPEN_LOG" ]] || fail "missing input invoked fake open"
  echo 'PASS: missing input'
}

run_missing_prompt_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"
  rm "$CASE_DIR/Companion/inbox-transcription-prompt.txt"

  if run_cli "$stdout_path" "$stderr_path" "$INPUT_PATH"; then
    fail "missing prompt invocation unexpectedly succeeded"
  fi

  assert_failure_code "$stdout_path" "prompt_missing"
  [[ ! -e "$FAKE_OPEN_LOG" ]] || fail "missing prompt invoked fake open"
  echo 'PASS: missing prompt'
}

run_invalid_utf8_prompt_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"
  printf '\377' > "$CASE_DIR/Companion/inbox-transcription-prompt.txt"

  if run_cli "$stdout_path" "$stderr_path" "$INPUT_PATH"; then
    fail "invalid UTF-8 prompt invocation unexpectedly succeeded"
  fi

  assert_failure_code "$stdout_path" "prompt_invalid_utf8"
  [[ ! -e "$FAKE_OPEN_LOG" ]] || fail "invalid UTF-8 prompt invoked fake open"
  echo 'PASS: invalid UTF-8 prompt'
}

run_timeout_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"

  if VOICEINK_FAKE_OPEN_MODE=timeout run_cli "$stdout_path" "$stderr_path" --timeout 1 "$INPUT_PATH"; then
    fail "timeout invocation unexpectedly succeeded"
  fi

  assert_failure_code "$stdout_path" "timeout"
  [[ -s "$FAKE_OPEN_LOG" ]] || fail "timeout did not invoke fake open"
  [[ -e "$CASE_DIR/cancel-observed.txt" ]] || fail "timeout did not write a cancellation marker"
  echo 'PASS: timeout'
}

run_input_checksum_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"
  local before
  local after
  before="$(shasum -a 256 "$INPUT_PATH" | awk '{print $1}')"

  run_cli_expecting_success "$stdout_path" "$stderr_path" "$INPUT_PATH"

  after="$(shasum -a 256 "$INPUT_PATH" | awk '{print $1}')"
  assert_equal "$before" "$after" "input checksum"
  echo 'PASS: input checksum'
}

run_request_directory_cleanup_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"

  run_cli_expecting_success "$stdout_path" "$stderr_path" "$INPUT_PATH"

  if find "$CASE_DIR/tmp/voiceink-inbox-companion" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q .; then
    fail "request directory remains after CLI exit"
  fi
  echo 'PASS: request directory cleanup'
}

run_request_id_association_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"
  local request_id='11111111-2222-4333-8444-555555555555'

  run_cli_expecting_success "$stdout_path" "$stderr_path" --request-id "$request_id" "$INPUT_PATH"

  assert_equal "$request_id" "$(json_value "$stdout_path" requestId)" "response request ID"
  echo 'PASS: request ID association'
}

run_invalid_request_id_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"

  if run_cli "$stdout_path" "$stderr_path" --request-id not-a-uuid "$INPUT_PATH"; then
    fail "invalid request ID invocation unexpectedly succeeded"
  fi

  [[ ! -s "$stderr_path" ]] || fail "invalid request ID wrote stderr"
  assert_failure_code "$stdout_path" "invalid_invocation"
  assert_response_has_uuid_request_id "$stdout_path"
  echo 'PASS: invalid request ID response UUID'
}

run_launch_failure_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"

  if VOICEINK_TEST_OPEN_COMMAND="$CASE_DIR/bin/failing-open" run_cli "$stdout_path" "$stderr_path" "$INPUT_PATH"; then
    fail "launch failure invocation unexpectedly succeeded"
  fi

  [[ ! -s "$stderr_path" ]] || fail "launch failure leaked stderr instead of returning JSON envelope"
  assert_failure_code "$stdout_path" "voiceink_unavailable"
  echo 'PASS: launch failure envelope'
}

run_prompt_anchor_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"

  run_cli_expecting_success "$stdout_path" "$stderr_path" "$INPUT_PATH"

  assert_equal "success" "$(json_value "$stdout_path" status)" "anchored success status"
  assert_equal "$ANCHOR_PROMPT" "$(cat "$CASE_DIR/prompt-observed.txt")" "request prompt path anchor"
  [[ -f "$ANCHOR_CLI" && -x "$ANCHOR_CLI" ]] || fail "anchor is missing the executable the bridge requires"
  cmp -s "$CLI_SOURCE" "$ANCHOR_CLI" || fail "installed anchor CLI differs from the repository CLI"
  cmp -s "$PROMPT_SOURCE" "$ANCHOR_PROMPT" || fail "installed anchor prompt differs from the repository prompt"
  assert_equal "700" "$(file_mode "$ANCHOR_DIR")" "anchor directory mode"
  assert_equal "700" "$(file_mode "$ANCHOR_CLI")" "anchor CLI mode"
  assert_equal "600" "$(file_mode "$ANCHOR_PROMPT")" "anchor prompt mode"
  echo 'PASS: prompt anchor installation'
}

run_prompt_anchor_preserves_user_edit_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"
  local edited='Отредактированный пользователем контекст.'

  run_cli_expecting_success "$stdout_path" "$stderr_path" "$INPUT_PATH"
  assert_equal "success" "$(json_value "$stdout_path" status)" "first anchored run status"

  printf '%s\n' "$edited" > "$ANCHOR_PROMPT"
  run_cli_expecting_success "$stdout_path" "$stderr_path" "$INPUT_PATH"

  assert_equal "success" "$(json_value "$stdout_path" status)" "second anchored run status"
  assert_equal "$edited" "$(cat "$ANCHOR_PROMPT")" "anchor prompt survives a rerun"
  assert_equal "$ANCHOR_PROMPT" "$(cat "$CASE_DIR/prompt-observed.txt")" "rerun prompt path anchor"
  echo 'PASS: prompt anchor preserves user edit'
}

run_trailing_slash_tmpdir_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"

  # macOS exports TMPDIR with a trailing slash. A doubled separator makes VoiceInk reject the
  # request path as non-canonical and never write a response, so the CLI must normalize it.
  VOICEINK_TEST_TMPDIR="$CASE_DIR/tmp/" run_cli_expecting_success "$stdout_path" "$stderr_path" "$INPUT_PATH"

  assert_equal "success" "$(json_value "$stdout_path" status)" "trailing slash TMPDIR status"
  if grep -q '%2F%2F' "$FAKE_OPEN_LOG"; then
    fail "request path contains a doubled separator: $(cat "$FAKE_OPEN_LOG")"
  fi
  echo 'PASS: trailing slash TMPDIR'
}

run_app_failure_exit_status_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"

  # A failure VoiceInk reported must not look like success to a shell caller.
  if VOICEINK_FAKE_OPEN_MODE=app-failure run_cli "$stdout_path" "$stderr_path" "$INPUT_PATH"; then
    fail "app-reported failure exited zero: $(cat "$stdout_path")"
  fi

  [[ ! -s "$stderr_path" ]] || fail "app-reported failure wrote stderr"
  assert_failure_code "$stdout_path" "inbox_mode_duplicate"
  echo 'PASS: app-reported failure exit status'
}

run_symlinked_anchor_case() {
  prepare_case
  local stdout_path="$CASE_DIR/stdout.json"
  local stderr_path="$CASE_DIR/stderr.txt"

  mkdir -p "$CASE_HOME/Library/Application Support" "$CASE_DIR/elsewhere"
  ln -s "$CASE_DIR/elsewhere" "$CASE_HOME/Library/Application Support/VoiceInk"

  if run_cli "$stdout_path" "$stderr_path" "$INPUT_PATH"; then
    fail "symlinked anchor invocation unexpectedly succeeded"
  fi

  [[ ! -s "$stderr_path" ]] || fail "symlinked anchor leaked stderr instead of returning JSON envelope"
  assert_failure_code "$stdout_path" "internal_failure"
  [[ ! -e "$FAKE_OPEN_LOG" ]] || fail "symlinked anchor invoked fake open"
  echo 'PASS: symlinked anchor rejected'
}

run_requested_case() {
  case "$1" in
    invalid-request-id)
      run_invalid_request_id_case
      ;;
    launch-failure)
      run_launch_failure_case
      ;;
    *)
      fail "unknown focused test case: $1"
      ;;
  esac
}

require_cli
if [[ -n "${VOICEINK_COMPANION_TEST_CASE:-}" ]]; then
  run_requested_case "$VOICEINK_COMPANION_TEST_CASE"
  exit 0
fi

run_success_case
run_missing_input_case
run_missing_prompt_case
run_invalid_utf8_prompt_case
run_timeout_case
run_input_checksum_case
run_request_directory_cleanup_case
run_request_id_association_case
run_invalid_request_id_case
run_launch_failure_case
run_prompt_anchor_case
run_prompt_anchor_preserves_user_edit_case
run_trailing_slash_tmpdir_case
run_app_failure_exit_status_case
run_symlinked_anchor_case

echo 'inbox companion CLI tests passed'
