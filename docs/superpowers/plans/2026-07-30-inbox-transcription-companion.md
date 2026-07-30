# VoiceInk Inbox Transcription Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a non-interactive inbox-audio transcription command that uses the installed VoiceInk app's current `Inbox` mode and transcription stack without creating History or Recordings artifacts.

**Architecture:** A repository-owned Bash CLI creates a private request directory, writes a versioned JSON request, and invokes a private VoiceInk URL scheme. A minimal in-app bridge validates the request, snapshots the current `Inbox` runtime, runs the same batch service registry and deterministic cleanup used by **Transcribe Audio**, writes one request-associated JSON response, and never creates a `Transcription` model. The bridge is the single compatibility boundary required because only the VoiceInk process has reliable access to its SwiftData dictionary, installed model managers, and Keychain/UserDefaults credentials.

**Tech Stack:** macOS 14.4+, Swift 5, Swift Concurrency, SwiftData, AVFoundation, CryptoKit, swift-atomics, Bash 3.2, Xcode 16+/GitHub Actions `macos-26`.

## Global Constraints

- The only companion-owned transcription setting is `Companion/inbox-transcription-prompt.txt`, a version-controlled UTF-8 file read at the start of every request.
- VoiceInk must contain exactly one enabled mode whose name is exactly `Inbox`; AI enhancement on that mode is a configuration error.
- Model, provider, language, formatting, vocabulary, word replacements, local model installation, and credentials come from the installed VoiceInk runtime on every request.
- The input file is read-only and must keep the same checksum after success, failure, cancellation, and timeout.
- No request may create VoiceInk History or Recordings artifacts, change VoiceInk settings, use the clipboard, paste, type, route KnowledgeBase content, or create Reminders.
- No credential, credential identifier, prompt content, complete VoiceInk configuration, unrelated history, or personal fixture may appear in output, logs, temporary files, or tests.
- Cloud transcription may contact only the provider selected by the `Inbox` mode; there is no fallback.
- Concurrent requests are serialized by returning an explicit `busy` result to the additional caller.
- The result contract is version `1`; an unknown version fails before audio processing.
- Temporary files are request-scoped and removed after success, failure, cancellation, or timeout.
- Existing VoiceInk behavior must be unchanged unless the private companion URL scheme is explicitly invoked.
- Local Xcode and Swift compilation are unavailable on the development Mac; Bash tests run locally, while Swift compilation, unit tests, app build, and end-to-end verification run on GitHub Actions.
- To observe a Swift test fail before implementation without retaining a broken commit on the feature branch, create a disposable worktree from the current feature HEAD, apply only the new failing test there, push it to the exact task-specific scratch ref named below, run the companion workflow on that ref, then remove the disposable worktree and remote scratch branch after the expected failure. The feature branch receives the test and implementation together only after RED is established.

---

### Task 1: Versioned Request/Result Contract and External CLI

**Files:**
- Create: `VoiceInk/InboxCompanion/Shared/InboxCompanionContract.swift`
- Create: `Companion/voiceink-inbox-transcribe`
- Create: `Companion/inbox-transcription-prompt.txt`
- Create: `tests/inbox-companion-cli-test.sh`
- Create: `.github/workflows/test-inbox-companion.yml`
- Modify: `Makefile`

**Interfaces:**
- Consumes: one input path, optional `--request-id UUID`, and optional `--timeout SECONDS`.
- Produces: `InboxCompanionRequest`, `InboxCompanionResponse`, `InboxCompanionSuccess`, `InboxCompanionFailure`, and executable `Companion/voiceink-inbox-transcribe`.
- Transport: scheme `voiceink-inbox`, host `transcribe`, and a `request` query item whose value is the percent-encoded absolute request JSON path.

- [ ] **Step 1: Write failing Bash contract tests**

Create `tests/inbox-companion-cli-test.sh` with isolated temporary directories and a fake open command. The fake command decodes the request path from the URL, validates that the request contains only contract version, request ID, input path, prompt path, response path, cancellation path, and timeout, then writes a fixed version-1 response.

Cover these observable behaviors:

```bash
run_success_case                       # one JSON success on stdout, no stderr
run_missing_input_case                 # input_missing failure, fake open not invoked
run_missing_prompt_case                # prompt_missing failure, fake open not invoked
run_invalid_utf8_prompt_case           # prompt_invalid_utf8 failure, fake open not invoked
run_timeout_case                       # timeout failure and cancellation marker
run_input_checksum_case                # checksum unchanged
run_request_directory_cleanup_case     # no request directory remains
run_request_id_association_case        # supplied UUID is unchanged in response
```

The test-specific override is `VOICEINK_COMPANION_OPEN_COMMAND`; production defaults to `/usr/bin/open`. The fake must never receive audio bytes or prompt contents.

- [ ] **Step 2: Run the Bash test and verify RED**

Run:

```bash
bash tests/inbox-companion-cli-test.sh
```

Expected: FAIL because `Companion/voiceink-inbox-transcribe` does not exist.

- [ ] **Step 3: Add the exact Swift contract**

Define value-only `Codable`, `Equatable`, and `Sendable` types:

```swift
enum InboxCompanionContract {
    static let version = 1
    static let scheme = "voiceink-inbox"
    static let host = "transcribe"
}

struct InboxCompanionRequest: Codable, Equatable, Sendable {
    let contractVersion: Int
    let requestId: UUID
    let inputPath: String
    let promptPath: String
    let responsePath: String
    let cancellationPath: String
    let timeoutSeconds: Double
}

enum InboxCompanionStatus: String, Codable, Sendable {
    case success
    case failure
}

enum InboxCompanionFailureCode: String, Codable, Sendable {
    case invalidInvocation = "invalid_invocation"
    case incompatibleContract = "incompatible_contract"
    case voiceInkUnavailable = "voiceink_unavailable"
    case inputMissing = "input_missing"
    case inputUnsupported = "input_unsupported"
    case inputUnreadable = "input_unreadable"
    case promptMissing = "prompt_missing"
    case promptUnreadable = "prompt_unreadable"
    case promptInvalidUTF8 = "prompt_invalid_utf8"
    case inboxModeMissing = "inbox_mode_missing"
    case inboxModeDisabled = "inbox_mode_disabled"
    case inboxModeDuplicate = "inbox_mode_duplicate"
    case aiEnhancementEnabled = "ai_enhancement_enabled"
    case modelNotSelected = "model_not_selected"
    case modelNotFound = "model_not_found"
    case modelUnavailable = "model_unavailable"
    case credentialMissing = "credential_missing"
    case authenticationFailed = "authentication_failed"
    case rateLimited = "rate_limited"
    case networkFailure = "network_failure"
    case providerFailure = "provider_failure"
    case emptyTranscript = "empty_transcript"
    case busy
    case cancelled
    case timeout
    case internalFailure = "internal_failure"
}

struct InboxCompanionModeIdentity: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
}

struct InboxCompanionModelIdentity: Codable, Equatable, Sendable {
    let name: String
    let displayName: String
    let provider: String
}

enum InboxCompanionExecutionKind: String, Codable, Sendable {
    case local
    case cloud
}

struct InboxCompanionPromptMetadata: Codable, Equatable, Sendable {
    let applied: Bool
    let sha256: String
}

struct InboxCompanionSuccess: Codable, Equatable, Sendable {
    let transcript: String
    let mode: InboxCompanionModeIdentity
    let model: InboxCompanionModelIdentity
    let language: String
    let mediaDurationSeconds: Double
    let execution: InboxCompanionExecutionKind
    let prompt: InboxCompanionPromptMetadata
    let aiEnhancementApplied: Bool
}

struct InboxCompanionFailure: Codable, Equatable, Sendable {
    let code: InboxCompanionFailureCode
    let phase: String
    let message: String
    let retryable: Bool
}

struct InboxCompanionResponse: Codable, Equatable, Sendable {
    let contractVersion: Int
    let requestId: UUID
    let status: InboxCompanionStatus
    let result: InboxCompanionSuccess?
    let error: InboxCompanionFailure?
}
```

Add factory methods that make success mutually exclusive with error. Configure `JSONEncoder` with `.sortedKeys` and `.withoutEscapingSlashes`.

- [ ] **Step 4: Implement the Bash CLI**

The executable must:

```bash
set -euo pipefail
umask 077
```

It resolves the prompt relative to its own directory, validates the input without modifying it, validates UTF-8 with `/usr/bin/iconv`, creates a request directory below `${TMPDIR:-/tmp}/voiceink-inbox-companion`, builds JSON with `/usr/bin/plutil`, invokes:

```bash
"$open_command" -gj -a "${VOICEINK_COMPANION_APP:-VoiceInk}" "$invocation_url"
```

It polls only its own `response.json`, emits that file exactly once to stdout, writes `cancel` on signal or timeout, and removes the whole request directory in an `EXIT` trap. All CLI-originated failures use the same response envelope and never include prompt content.

- [ ] **Step 5: Add a safe initial prompt and Make targets**

Create `Companion/inbox-transcription-prompt.txt` with this non-sensitive UTF-8 context:

```text
Аудиозаметка для базы знаний. Термины могут быть на русском и английском языках.
```

Add:

```make
.PHONY: test-companion companion-transcribe

test-companion:
	bash tests/inbox-companion-cli-test.sh

companion-transcribe:
	@test -n "$(INPUT)" || { echo "Usage: make companion-transcribe INPUT=/path/to/audio" >&2; exit 2; }
	Companion/voiceink-inbox-transcribe "$(INPUT)"
```

- [ ] **Step 6: Add the remote macOS verification entrypoint**

Create a manual `macos-26` workflow named `Test inbox companion`, with run name `Test inbox companion ${{ inputs.request_id || github.run_number }}`, `contents: read`, a `request_id` input, and these initial steps:

```yaml
- uses: actions/checkout@v6
- run: make test-companion
- run: make whisper
- run: make test-companion-xcode
- run: make local
```

Add this target so later Swift tests can be watched failing and passing without installing Xcode locally:

```make
test-companion-xcode:
	xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk \
		-destination 'platform=macOS' \
		-derivedDataPath "$(CURDIR)/.local-build-tests" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		-only-testing:VoiceInkTests
```

- [ ] **Step 7: Run tests, commit, push, and verify the clean remote baseline**

Run:

```bash
make test-companion
git diff --check
```

Expected: all Bash cases PASS and no whitespace errors.

Commit:

```bash
git add VoiceInk/InboxCompanion/Shared/InboxCompanionContract.swift \
  Companion/voiceink-inbox-transcribe \
  Companion/inbox-transcription-prompt.txt \
  tests/inbox-companion-cli-test.sh \
  .github/workflows/test-inbox-companion.yml \
  Makefile
git commit -m "feat: add inbox companion contract and cli"
git push -u origin codex/inbox-transcription-companion
```

Dispatch the workflow on this branch and require a successful baseline app/test build before Task 2.

---

### Task 2: Strict Inbox Preflight and Side-Effect-Free Batch Pipeline

**Files:**
- Create: `VoiceInk/InboxCompanion/InboxCompanionPreflight.swift`
- Create: `VoiceInk/InboxCompanion/InboxTranscriptionRunner.swift`
- Create: `VoiceInk/InboxCompanion/InboxTranscriptionBackend.swift`
- Create: `VoiceInk/InboxCompanion/TranscriptionCancellationToken.swift`
- Create: `VoiceInkTests/InboxCompanionPreflightTests.swift`
- Create: `VoiceInkTests/InboxTranscriptionRunnerTests.swift`

**Interfaces:**
- Consumes: `InboxCompanionRequest`, current `[ModeConfig]`, `TranscriptionModelManager`, `ModelContext`, `VoiceInkEngine`.
- Produces: `InboxCompanionRuntimeSnapshot` and `InboxTranscriptionRunning.run(request:cancellation:)`.
- Reuses: `AudioProcessor`, `TranscriptionServiceRegistry`, `TranscriptionOutputFilter`, `ParagraphFormatter`, `WordReplacementService`, and `AudioFileMetadata`.

- [ ] **Step 1: Write failing preflight tests**

Use real `ModeConfig` values with literal expectations. Each mutation catches a different invalid branch:

```swift
@Test func missingInboxModeIsDistinct()
@Test func disabledInboxModeIsDistinct()
@Test func duplicateEnabledInboxModesAreDistinct()
@Test func aiEnhancedInboxModeIsRejected()
@Test func missingModelSelectionIsDistinct()
@Test func unavailableModelIsRejectedBeforeAudioPreparation()
@Test func missingCloudCredentialIsRejectedBeforeAudioPreparation()
@Test func missingPromptIsDistinct()
@Test func invalidUTF8PromptIsDistinct()
@Test func unknownContractVersionIsRejected()
```

Also assert that one enabled exact-case `Inbox` mode resolves its UUID, selected model, resolved language, formatting flag, prompt digest, and prompt-support flag.

- [ ] **Step 2: Run the focused test and verify RED in GitHub**

The first remote compilation run will use:

```bash
git push origin HEAD:codex/inbox-companion-red-task2
gh workflow run test-inbox-companion.yml \
  --repo sizzle1102/VoiceInk \
  --ref codex/inbox-companion-red-task2 \
  -f request_id=red-task2
```

Wait for the exact `red-task2` run. Expected: FAIL in `make test-companion-xcode` because `InboxCompanionPreflight` does not exist.

- [ ] **Step 3: Implement preflight as the compatibility boundary**

Define:

```swift
struct InboxCompanionRuntimeSnapshot {
    let mode: ModeConfig
    let transcription: TranscriptionRuntimeConfiguration
    let formatting: TranscriptionFormattingConfiguration
    let prompt: String
    let promptSHA256: String
    let promptApplied: Bool
}

@MainActor
enum InboxCompanionPreflight {
    static func resolve(
        request: InboxCompanionRequest,
        modes: [ModeConfig],
        transcriptionModelManager: TranscriptionModelManager
    ) throws -> InboxCompanionRuntimeSnapshot
}
```

Resolve exact `Inbox` names in this order: unknown contract, input, prompt, no matching mode, matching modes but none enabled, more than one enabled, enhancement enabled, model resolution, credential availability. Use `CryptoKit.SHA256` over the exact prompt bytes and never retain or expose the prompt beyond the runtime snapshot. Treat `.whisper`, `.fluidAudio`, and `.nativeApple` as local; all registered/custom providers are cloud. A prompt is applied only for providers whose existing batch implementation consumes `TranscriptionRequestContext.prompt` (currently `.whisper`).

- [ ] **Step 4: Write failing runner tests**

Create small real temporary input and output paths and injected fakes at the slow boundary. Tests assert outcomes, never fake call existence:

```swift
@Test func runnerReturnsCleanedTextWithoutCreatingTranscription()
@Test func runnerUsesRequestScopedWAVAndDeletesItAfterSuccess()
@Test func runnerDeletesTemporaryWAVAfterProviderFailure()
@Test func runnerReportsEmptyTranscriptAsFailure()
@Test func runnerMapsAuthenticationRateLimitAndNetworkFailuresDistinctly()
@Test func runnerNeverWritesToRecordingsDirectory()
@Test func runnerLeavesInputBytesUnchanged()
```

For cleanup parity, feed the literal raw text `"  um Привет [noise] voice ink.  "` through the real filter/formatter/replacement services and assert a hand-derived literal result after inserting an enabled `WordReplacement` into an in-memory SwiftData container.

- [ ] **Step 5: Implement injected audio/backend boundaries and the real runner**

Define:

```swift
protocol InboxAudioPreparing {
    func prepareReadOnlyInput(_ input: URL, wavOutput: URL) async throws -> TimeInterval
}

@MainActor
protocol InboxTranscriptionBackend {
    func transcribe(
        wavURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String
    func cleanup() async
}

@MainActor
protocol InboxTranscriptionRunning {
    func run(
        request: InboxCompanionRequest,
        snapshot: InboxCompanionRuntimeSnapshot,
        cancellation: TranscriptionCancellationToken
    ) async -> InboxCompanionResponse
}
```

The real audio preparer calls `AudioProcessor.processAudioToSamples`, saves `request-audio.wav` only inside the validated request directory, and obtains duration from the original input. The real backend wraps `TranscriptionServiceRegistry`. The runner applies:

```swift
var text = try await backend.transcribe(...)
text = TranscriptionOutputFilter.filter(text)
text = text.trimmingCharacters(in: .whitespacesAndNewlines)
if snapshot.formatting.isTextFormattingEnabled {
    text = ParagraphFormatter.format(text)
}
text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
```

The cleanup-parity test's hand-derived expected value is exactly `"Привет VoiceInk."`.

Create the token now because it is part of the runner interface:

```swift
import Atomics

final class TranscriptionCancellationToken: @unchecked Sendable {
    private let cancelled = ManagedAtomic(false)
    var isCancelled: Bool { cancelled.load(ordering: .acquiring) }
    func cancel() { cancelled.store(true, ordering: .releasing) }
    func throwIfCancelled() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }
}
```

It does not instantiate, insert, save, or notify about `Transcription`. A `defer` removes request-scoped WAV data and calls backend cleanup on every exit.

- [ ] **Step 6: Commit, push, and require a green remote run**

```bash
git add VoiceInk/InboxCompanion/InboxCompanionPreflight.swift \
  VoiceInk/InboxCompanion/InboxTranscriptionRunner.swift \
  VoiceInk/InboxCompanion/InboxTranscriptionBackend.swift \
  VoiceInk/InboxCompanion/TranscriptionCancellationToken.swift \
  VoiceInkTests/InboxCompanionPreflightTests.swift \
  VoiceInkTests/InboxTranscriptionRunnerTests.swift
git commit -m "feat: add side-effect-free inbox transcription pipeline"
git push origin codex/inbox-transcription-companion
gh workflow run test-inbox-companion.yml \
  --repo sizzle1102/VoiceInk \
  --ref codex/inbox-transcription-companion \
  -f request_id=green-task2
```

Wait for the exact `green-task2` run. Expected: all companion Bash tests, VoiceInk unit tests, and app build PASS.

---

### Task 3: Minimal In-App URL Bridge and Request Association

**Files:**
- Create: `VoiceInk/InboxCompanion/InboxCompanionBridge.swift`
- Create: `VoiceInkTests/InboxCompanionBridgeTests.swift`
- Modify: `VoiceInk/AppDelegate.swift`
- Modify: `VoiceInk/VoiceInk.swift`
- Modify: `VoiceInk/Info.plist`

**Interfaces:**
- Consumes: `voiceink-inbox://transcribe?request=...`.
- Produces: one atomically written `InboxCompanionResponse` at the request's exact `responsePath`.
- Concurrency: at most one active request; another valid request receives its own `busy` response.

- [ ] **Step 1: Write failing bridge tests**

Use a fake `InboxTranscriptionRunning` that returns literal responses and a real private temporary request directory. Cover:

```swift
@Test func unrelatedURLsAreNotHandled()
@Test func malformedInvocationProducesInvalidInvocationWhenRequestIdIsRecoverable()
@Test func requestOutsidePrivateTempRootIsRejected()
@Test func responsePathOutsideRequestDirectoryIsRejected()
@Test func symlinkedRequestDirectoryIsRejected()
@Test func successfulResponseIsWrittenAtomicallyToAssociatedPath()
@Test func overlappingRequestGetsBusyAtItsOwnResponsePath()
@Test func bridgeDoesNotPresentOrActivateVoiceInkUI()
```

The success test reads and decodes the actual JSON file; it does not assert that a fake method was called.

- [ ] **Step 2: Verify RED remotely**

Run:

```bash
git push origin HEAD:codex/inbox-companion-red-task3
gh workflow run test-inbox-companion.yml \
  --repo sizzle1102/VoiceInk \
  --ref codex/inbox-companion-red-task3 \
  -f request_id=red-task3
```

Wait for the exact `red-task3` run. Expected: FAIL in `make test-companion-xcode` because `InboxCompanionBridge` does not exist.

- [ ] **Step 3: Implement the bridge**

Define an `@MainActor final class InboxCompanionBridge` with:

```swift
func handles(_ url: URL) -> Bool
func handle(_ url: URL)
```

Canonicalize the request path and require it below `NSTemporaryDirectory()/voiceink-inbox-companion/`, owned by the current UID, with `response.json` and `cancel` in the same non-symlinked request directory. Limit request JSON to 64 KiB. Decode exactly contract version `1`. Write responses to a sibling temporary file and rename atomically. Log only request ID, phase, failure code, and durations; never log input path, prompt, transcript, configuration dumps, or credential details.

- [ ] **Step 4: Wire the bridge without changing normal open-file behavior**

Register this URL type:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.prakashjoshipax.VoiceInk.InboxCompanion</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>voiceink-inbox</string>
    </array>
  </dict>
</array>
```

Add `AppDelegate.configureInboxCompanionBridge(_:)`, a small pending-URL queue for cold start, and an early companion-scheme branch in `application(_:open:)`. That branch must return before all existing activation/window/navigation code. Construct the bridge at the end of `VoiceInkApp.init()` from the already-created `ModelContainer`, engine, and transcription model manager.

- [ ] **Step 5: Commit, push, and require a green remote run**

```bash
git add VoiceInk/InboxCompanion/InboxCompanionBridge.swift \
  VoiceInkTests/InboxCompanionBridgeTests.swift \
  VoiceInk/AppDelegate.swift \
  VoiceInk/VoiceInk.swift \
  VoiceInk/Info.plist
git commit -m "feat: add private inbox companion bridge"
git push origin codex/inbox-transcription-companion
gh workflow run test-inbox-companion.yml \
  --repo sizzle1102/VoiceInk \
  --ref codex/inbox-transcription-companion \
  -f request_id=green-task3
```

Wait for the exact `green-task3` run. Expected: all companion Bash tests, VoiceInk unit tests, and app build PASS.

---

### Task 4: Bounded Cancellation and Timeout Through the Batch Stack

**Files:**
- Create: `VoiceInkTests/InboxCompanionCancellationTests.swift`
- Modify: `VoiceInk/InboxCompanion/TranscriptionCancellationToken.swift`
- Modify: `VoiceInk/Transcription/Engine/TranscriptionService.swift`
- Modify: `VoiceInk/Transcription/Whisper/WhisperTranscriptionService.swift`
- Modify: `VoiceInk/Transcription/Whisper/LibWhisper.swift`
- Modify: `VoiceInk/InboxCompanion/InboxCompanionBridge.swift`
- Modify: `VoiceInk/InboxCompanion/InboxTranscriptionRunner.swift`

**Interfaces:**
- Consumes: request deadline, `cancel` marker, task cancellation.
- Produces: distinct `cancelled` or `timeout` failure; an atomic abort flag visible to whisper.cpp.

- [ ] **Step 1: Write failing cancellation tests**

Cover:

```swift
@Test func cancellationMarkerReturnsCancelledAndRemovesTemporaryAudio()
@Test func deadlineReturnsTimeoutAndRemovesTemporaryAudio()
@Test func cancellationTokenIsVisibleAcrossThreads()
@Test func operationCompletionWinsADeadlineRace()
@Test func timeoutResponseKeepsOriginalRequestId()
```

Use a fake backend that suspends until the real token changes. Verify result files and temporary-file deletion, not fake call counts.

- [ ] **Step 2: Verify RED remotely**

Run:

```bash
git push origin HEAD:codex/inbox-companion-red-task4
gh workflow run test-inbox-companion.yml \
  --repo sizzle1102/VoiceInk \
  --ref codex/inbox-companion-red-task4 \
  -f request_id=red-task4
```

Wait for the exact `red-task4` run. Expected: FAIL in `make test-companion-xcode` because the token and deadline race do not exist.

- [ ] **Step 3: Connect the existing lock-free cancellation token to request contexts**

Add `let cancellation: TranscriptionCancellationToken?` to `TranscriptionRequestContext`; default and existing call sites use `nil`, and `scoped(to:)` preserves it.

- [ ] **Step 4: Connect whisper.cpp's supported abort callback**

Change `WhisperContext.fullTranscribe` to accept the optional token. Set `whisper_full_params.abort_callback` to a non-capturing C callback that reads the retained token from `abort_callback_user_data`, and keep the token alive with `withExtendedLifetime` across `whisper_full`. Treat an aborted `whisper_full` as `CancellationError`, not `whisperCoreFailed`. Existing callers with `nil` retain byte-for-byte behavior.

- [ ] **Step 5: Race operation, cancel marker, and deadline**

The bridge starts one unstructured operation task plus a watcher that checks the request-scoped cancel marker and `ContinuousClock` deadline. On cancellation or timeout it sets the shared token and cancels the operation task; it awaits cleanup, writes exactly one failure, and clears the busy state. If the operation completes first, cancel the watcher and write the operation response.

- [ ] **Step 6: Commit, push, and require a green remote run**

```bash
git add VoiceInk/InboxCompanion/TranscriptionCancellationToken.swift \
  VoiceInkTests/InboxCompanionCancellationTests.swift \
  VoiceInk/Transcription/Engine/TranscriptionService.swift \
  VoiceInk/Transcription/Whisper/WhisperTranscriptionService.swift \
  VoiceInk/Transcription/Whisper/LibWhisper.swift \
  VoiceInk/InboxCompanion/InboxCompanionBridge.swift \
  VoiceInk/InboxCompanion/InboxTranscriptionRunner.swift
git commit -m "feat: add bounded companion cancellation"
git push origin codex/inbox-transcription-companion
gh workflow run test-inbox-companion.yml \
  --repo sizzle1102/VoiceInk \
  --ref codex/inbox-transcription-companion \
  -f request_id=green-task4
```

Wait for the exact `green-task4` run. Expected: all companion Bash tests, VoiceInk unit tests, and app build PASS.

---

### Task 5: GitHub Verification, Installed-App E2E, and Operator Documentation

**Files:**
- Modify: `.github/workflows/test-inbox-companion.yml`
- Create: `tests/inbox-companion-e2e.sh`
- Create: `docs/inbox-transcription-companion.md`
- Create: `docs/superpowers/specs/2026-07-30-inbox-transcription-companion-bridge-justification.md`
- Modify: `Makefile`

**Interfaces:**
- Consumes: workflow-dispatch ref and optional `request_id`.
- Produces: Bash test results, Xcode unit-test results, local app build, and an installed-app Russian M4A smoke result artifact with no transcript or credentials uploaded.

- [ ] **Step 1: Extend the CI workflow**

Extend the manual workflow on `macos-26` so its existing steps are followed by:

```yaml
- run: bash tests/inbox-companion-e2e.sh
```

Use `permissions: contents: read`. Upload only `.xcresult` on failure; never upload request directories, prompt contents, audio, transcript, defaults, Keychain data, or app support stores.

- [ ] **Step 2: Add the exact Xcode test target**

Add:

```make
test-companion-xcode:
	xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk \
		-destination 'platform=macOS' \
		-derivedDataPath "$(CURDIR)/.local-build-tests" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		-only-testing:VoiceInkTests
```

- [ ] **Step 3: Create a non-sensitive installed-app E2E**

The script must:

1. Use the just-built `$HOME/Downloads/VoiceInk.app`.
2. Generate a short Russian M4A with macOS `say` and `afconvert`; do not commit or upload it.
3. Download `ggml-tiny.bin` to VoiceInk's normal `WhisperModels` directory.
4. Seed one enabled, non-enhanced exact `Inbox` mode with model `ggml-tiny`, language `ru`, and formatting disabled in the app's real UserDefaults domain.
5. Launch the app hidden through the companion URL while initially closed, then invoke a second request while it is running.
6. Assert both responses are contract version `1`, status `success`, mode `Inbox`, provider `Whisper`, language `ru`, local execution, prompt applied, and AI enhancement false.
7. Assert the input checksum, VoiceInk settings snapshot, History count, and Recordings listing are unchanged across each request.
8. Exercise an invalid prompt and duplicate mode failure without contacting a provider.
9. Remove only its generated fixture, downloaded model, seeded test defaults, and request directories.

- [ ] **Step 4: Document use and the bridge justification**

`docs/inbox-transcription-companion.md` must show:

```bash
Companion/voiceink-inbox-transcribe /absolute/path/to/audio.m4a
Companion/voiceink-inbox-transcribe --request-id "$REQUEST_ID" --timeout 900 /absolute/path/to/audio.m4a
```

Document the result envelope, failure codes, prompt path, exact `Inbox` requirements, no-history guarantees, and the fact that stderr is diagnostics only while stdout is one JSON result.

The bridge justification must record verified constraints:

- modes are process-owned `ModeManager` state loaded from VoiceInk's defaults;
- dictionary and replacements are in VoiceInk's SwiftData container;
- standard builds protect provider credentials with VoiceInk's Keychain access group, while local builds use VoiceInk defaults;
- installed local-model managers and provider registry are already initialized in the app;
- UI automation and the existing **Transcribe Audio** flow create forbidden persistent artifacts;
- therefore an external process cannot safely preserve all required semantics, and the private URL bridge is the smallest replaceable compatibility boundary.

- [ ] **Step 5: Commit verification support**

```bash
git add .github/workflows/test-inbox-companion.yml \
  tests/inbox-companion-e2e.sh \
  docs/inbox-transcription-companion.md \
  docs/superpowers/specs/2026-07-30-inbox-transcription-companion-bridge-justification.md \
  Makefile
git commit -m "test: verify inbox companion on macos"
```

- [ ] **Step 6: Run local checks, push the branch, and dispatch GitHub verification**

Run locally:

```bash
make test-companion
bash tests/install-app-test.sh
bash tests/update-build-sign-install-test.sh
git diff --check
```

Push the current feature branch, then dispatch:

```bash
gh workflow run test-inbox-companion.yml \
  --repo sizzle1102/VoiceInk \
  --ref codex/inbox-transcription-companion \
  -f request_id=inbox-companion-$(date -u +%Y%m%dT%H%M%SZ)
```

Wait for completion and inspect the exact run. Expected: Bash tests, Swift tests, app build, and installed-app E2E all PASS.

---

### Task 6: Whole-Branch Verification and Compatibility Audit

**Files:**
- Modify only files required by findings from the scoped final review.

**Interfaces:**
- Consumes: complete branch diff from `1eeb4c5`.
- Produces: a reviewed branch with all acceptance evidence recorded in the task handoff.

- [ ] **Step 1: Audit spec coverage**

Map every acceptance criterion in `docs/superpowers/specs/2026-07-30-inbox-transcription-companion-design.md` to a unit test, Bash test, or installed-app E2E assertion. Any uncovered criterion is an implementation gap, not a documentation note.

- [ ] **Step 2: Review security and side effects**

Inspect the full diff for:

```text
credential or prompt logging
transcript persistence
arbitrary response-path writes
symlink traversal
UI activation on companion URLs
provider fallback
history/recordings insertion
input mutation
ambiguous request matching
temporary-file leaks
normal VoiceInk behavior changes
```

- [ ] **Step 3: Run the complete verification set**

Local:

```bash
make test-companion
bash tests/install-app-test.sh
bash tests/voiceink-install-common-test.sh
bash tests/update-build-sign-install-test.sh
bash tests/update-build-sign-install-remote-test.sh
bash tests/update-build-sign-install-signing-test.sh
bash tests/sync-upstream-workflow-test.sh
git diff --check 1eeb4c5..HEAD
```

Remote:

```bash
RUN_ID="$(gh run list --repo sizzle1102/VoiceInk \
  --workflow test-inbox-companion.yml \
  --branch codex/inbox-transcription-companion \
  --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view "$RUN_ID" --repo sizzle1102/VoiceInk --log-failed
gh run view "$RUN_ID" --repo sizzle1102/VoiceInk \
  --json status,conclusion,headSha,workflowName,url
```

Expected: every local test exits `0`; the remote run is `completed/success` on the exact branch HEAD.

- [ ] **Step 4: Final commit if review fixes were required**

Stage only reviewed findings and commit with a focused Conventional Commit message. If no fixes are required, do not create an empty commit.
