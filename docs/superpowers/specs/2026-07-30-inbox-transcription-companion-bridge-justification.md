# Why the inbox companion needs an in-app bridge

The companion is a repository-owned Bash CLI plus a private URL bridge inside VoiceInk. The
bridge is the only new compatibility surface, and it exists because the required semantics —
"use the installed app's current `Inbox` mode and transcription stack, and leave no History or
Recordings artifact" — cannot all be preserved from outside the VoiceInk process.

Each constraint below was verified against this branch, not assumed.

## Verified constraints

### Modes are process-owned state, not a readable file format

`ModeManager.shared` is an `ObservableObject` singleton holding `@Published configurations`
([ModeConfig.swift:279](../../../VoiceInk/Modes/ModeConfig.swift#L279)), loaded from
`UserDefaults` key `modeConfigurationsV2` through a migration path
([ModeConfig.swift:284](../../../VoiceInk/Modes/ModeConfig.swift#L284),
[ModeDataMigration.swift](../../../VoiceInk/Modes/ModeDataMigration.swift)). `ModeConfig`'s
decoder falls back to *other* live `UserDefaults` keys for several fields
([ModeConfig.swift:172](../../../VoiceInk/Modes/ModeConfig.swift#L172)), so the effective mode
is a function of app state, not of the stored blob alone. An external reader would have to
reimplement that migration and fallback behaviour and would drift the moment it changes.

The bridge instead resolves the mode from `ModeManager.shared.configurations`
([VoiceInk.swift:176](../../../VoiceInk/VoiceInk.swift#L176)) — the same value the app itself
acts on.

### Vocabulary and word replacements live in VoiceInk's SwiftData container

Cleanup parity requires `WordReplacementService` against the app's `ModelContext`
([InboxTranscriptionRunner.swift:45](../../../VoiceInk/InboxCompanion/InboxTranscriptionRunner.swift#L45)).
That container is opened by the app at
[VoiceInk.swift:230](../../../VoiceInk/VoiceInk.swift#L230) across three stores
(`default.store`, `dictionary.store`, `stats.store`), with CloudKit configuration applied per
store. Opening the same stores from a second process concurrently is not a supported use of
that container.

### Provider credentials are not reachable from another process in standard builds

`KeychainService` scopes items to service `com.prakashjoshipax.VoiceInk` and, in standard
builds, to VoiceInk's Keychain access group; only local builds fall back to storing them in
VoiceInk's `UserDefaults`
([KeychainService.swift:10](../../../VoiceInk/Services/KeychainService.swift#L10),
[KeychainService.swift:36](../../../VoiceInk/Services/KeychainService.swift#L36)). A separate
binary is not in that access group, so it cannot read cloud provider credentials at all — and
must not, since duplicating credential access would widen the attack surface for no gain.

### Installed model managers and the provider registry are already initialized in the app

`WhisperModelManager`, `FluidAudioModelManager`, `TranscriptionModelManager` and
`TranscriptionServiceRegistry` are constructed during app start over
`…/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels`
([VoiceInk.swift:106](../../../VoiceInk/VoiceInk.swift#L106),
[VoiceInkEngine.swift:145](../../../VoiceInk/Transcription/Engine/VoiceInkEngine.swift#L145)).
Resolving "is this model actually installed, and which service handles this provider" outside
the app would mean re-deriving that registry, including imported models.

### The existing user-facing path creates exactly the artifacts we must not create

**Transcribe Audio** inserts `Transcription` rows on every branch of
[AudioFileTranscriptionService.swift:130](../../../VoiceInk/Services/AudioFileTranscriptionService.swift#L130)
and writes into the Recordings directory
([AudioFileTranscriptionService.swift:91](../../../VoiceInk/Services/AudioFileTranscriptionService.swift#L91)).
Driving that flow — or driving the UI through automation — therefore cannot satisfy the
no-History, no-Recordings requirement. Nor can UI automation avoid presenting windows, which
the companion must never do.

## Conclusion

An external process can neither read the effective mode, nor share the SwiftData container,
nor obtain provider credentials, nor reuse the initialized model registry; and the one existing
in-app path that does all of those creates forbidden persistent artifacts.

So the work has to happen inside the VoiceInk process, and the only question is how little
surface that requires. The bridge is that minimum: one private URL scheme, one closed
seven-key request schema, one atomically written response, no UI, and no change to any existing
behaviour unless the companion scheme is explicitly invoked. It is deliberately small enough to
be replaced wholesale — by a real IPC endpoint or an app extension — without touching the
contract the CLI depends on.

## What the bridge deliberately does not trust

- The request path must resolve below `$TMPDIR/voiceink-inbox-companion/`, one level deep,
  reached through `openat`/`O_NOFOLLOW` with owner and mode checks rather than path strings
  ([InboxCompanionBridge.swift](../../../VoiceInk/InboxCompanion/InboxCompanionBridge.swift)).
- The request JSON is capped at 64 KiB, must contain exactly the seven contract keys with no
  duplicates, and may not contain nested containers.
- The prompt is **not** taken from the request. The request's `promptPath` is only asserted
  equal to the fixed anchor, and the bytes are re-read from the anchor's own descriptor.
- Responses are written to a sibling temporary file and `renameat`-ed into place, so a reader
  never observes a partial result.
- Logs carry only a hashed request id, phase, failure code and elapsed seconds — never the
  input path, prompt, transcript, configuration, or credential details.
