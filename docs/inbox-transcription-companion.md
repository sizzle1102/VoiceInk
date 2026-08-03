# Inbox transcription companion

A non-interactive command that transcribes an audio file using the installed VoiceInk app's
current `Inbox` mode, without creating any History or Recordings artifact.

## Usage

```bash
Companion/voiceink-inbox-transcribe /absolute/path/to/audio.m4a
```

```bash
Companion/voiceink-inbox-transcribe --request-id "$REQUEST_ID" --timeout 900 /absolute/path/to/audio.m4a
```

`--request-id` must be a UUID and is echoed back in the result, so a caller can correlate a
response with the request it issued — **compare it case-insensitively.** A failure this command
detects on its own echoes the identifier exactly as supplied, while any result VoiceInk itself
produces comes back as an uppercase UUID, so the two paths can report one request in different
case. `--timeout` is a positive whole number of seconds and defaults to `300`.

**stdout carries exactly one JSON result. stderr is diagnostics only** — never parse stderr,
and never treat a non-empty stderr as failure on its own. The exit status is `0` only for a
`success` result.

## Result envelope

Every result — including failures the command detects before VoiceInk is involved — uses the
same version-1 envelope:

```json
{
  "contractVersion": 1,
  "requestId": "9F1D1C62-1C2B-4A1E-9A3E-2F9A0B7D5E11",
  "status": "success",
  "result": {
    "transcript": "…",
    "mode": { "id": "…", "name": "Inbox" },
    "model": { "name": "ggml-large-v3", "displayName": "…", "provider": "Whisper" },
    "language": "ru",
    "mediaDurationSeconds": 12.5,
    "execution": "local",
    "prompt": { "applied": true, "sha256": "…" },
    "aiEnhancementApplied": false
  },
  "error": null
}
```

A failure inverts the last two fields:

```json
{
  "contractVersion": 1,
  "requestId": "…",
  "status": "failure",
  "result": null,
  "error": { "code": "inbox_mode_missing", "phase": "preflight", "message": "…", "retryable": false }
}
```

`result` and `error` are mutually exclusive. `retryable` marks failures where the same request
may succeed later without any change — `timeout`, `busy`, `rate_limited`, `network_failure`,
and `provider_failure`.

### Failure codes

| Code | Meaning |
| --- | --- |
| `invalid_invocation` | Bad arguments: unknown option, non-UUID request id, non-positive timeout, or not exactly one input path. |
| `incompatible_contract` | The request contract version is not `1`. |
| `voiceink_unavailable` | VoiceInk could not be launched. |
| `input_missing` / `input_unsupported` / `input_unreadable` | The input path does not exist, is not a regular file, or cannot be read. |
| `prompt_missing` / `prompt_unreadable` / `prompt_invalid_utf8` | The installed prompt is absent, unsafe to read, or not valid UTF-8. |
| `inbox_mode_missing` / `inbox_mode_disabled` / `inbox_mode_duplicate` | There is no mode named exactly `Inbox`, the only one is disabled, or more than one enabled `Inbox` mode exists. |
| `ai_enhancement_enabled` | The `Inbox` mode has AI enhancement turned on, which this command refuses to run. |
| `model_not_selected` / `model_not_found` / `model_unavailable` | The mode selects no model, names one VoiceInk does not know, or names one that is not installed. |
| `credential_missing` / `authentication_failed` / `rate_limited` / `network_failure` / `provider_failure` | Cloud provider problems, reported only for the provider the `Inbox` mode selects. |
| `empty_transcript` | Transcription produced no text after cleanup. |
| `busy` | Another companion request is already running. |
| `cancelled` / `timeout` | The request was cancelled through its marker, or exceeded `--timeout`. |
| `internal_failure` | Anything else, including a companion support directory that cannot be prepared safely. |

## The prompt

The only companion-owned transcription setting is a single UTF-8 file:

```
~/Library/Application Support/VoiceInk/InboxCompanion/inbox-transcription-prompt.txt
```

VoiceInk trusts **only** that path. The command installs itself and seeds that file from
`Companion/inbox-transcription-prompt.txt` on first use, then leaves it alone — edit the
installed file to change the prompt and your edit survives every later run. The directory is
kept at `0700`, the installed executable at `0700`, and the prompt at `0600`; a symlinked
companion directory is rejected rather than followed.

The prompt is re-read from disk at the start of every request, and its SHA-256 is reported in
`result.prompt.sha256`. Its contents never appear in output, logs, or temporary files.
`result.prompt.applied` is `true` only for providers whose batch implementation actually
consumes a prompt — currently Whisper.

> The companion directory is deliberately `…/Application Support/VoiceInk/`, which is *not*
> the app's own support directory (`…/Application Support/com.prakashjoshipax.VoiceInk/`).
> Keeping companion state out of the app's store is what lets the app treat it as a fixed,
> app-independent trust anchor.

## What the `Inbox` mode must look like

- Exactly one mode named exactly `Inbox` — case-sensitive, no surrounding whitespace.
- That mode must be enabled. More than one enabled `Inbox` mode is a configuration error, not
  an ambiguity to resolve.
- AI enhancement on that mode must be off.

Model, provider, language, formatting, vocabulary, word replacements, local model installation
and credentials are all read from the installed VoiceInk runtime on every request. There is no
companion-side override and no provider fallback: if the mode selects a cloud provider, only
that provider is contacted.

## Guarantees

- **No History row and no Recordings file** is created. The command never constructs a
  `Transcription`, and never writes to the app's recordings directory.
- **VoiceInk settings are not changed**, the clipboard is not used, nothing is pasted or typed,
  no KnowledgeBase routing happens, and no reminder is created.
- **The input file is never modified.** Its checksum is identical after success, failure,
  cancellation, and timeout.
- **Temporary files are request-scoped.** The request directory below
  `$TMPDIR/voiceink-inbox-companion/` and the intermediate WAV inside it are removed on every
  exit path.
- **Requests are serialized.** A second concurrent request receives its own `busy` result at
  its own response path rather than queueing behind the first.
- **No UI is presented or activated.** A companion URL never brings VoiceInk forward, and mixed
  batches of URLs still open ordinary media normally.

## Verification

```bash
make test-companion          # Bash contract tests, no Xcode required
make test-companion-xcode    # Swift unit tests
make test-companion-e2e      # installed-app end-to-end, expects ~/Downloads/VoiceInk.app
```

Swift compilation and the end-to-end check run on GitHub Actions via
`build-local-app.yml`, with `run_companion_tests=true` and `run_companion_e2e=true`.
