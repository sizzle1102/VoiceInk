import Foundation
import SwiftData
import Testing

@testable import VoiceInk

@Suite(.serialized)
@MainActor
struct InboxCompanionCancellationTests {
    @Test func cancellationMarkerReturnsCancelledAndRemovesTemporaryAudio() async throws {
        let fixture = try makeFixture(timeoutSeconds: 30)
        let backend = SuspendingBackend()
        let bridge = makeBridge(runner: makeRunner(backend: backend, modelContext: fixture.modelContext))

        bridge.handle(invocationURL(for: fixture.requestURL))
        await backend.waitForStart()
        #expect(FileManager.default.fileExists(atPath: fixture.wavURL.path))
        try Data().write(to: fixture.cancellationURL)

        let response = try await waitForResponse(at: fixture.responseURL)
        #expect(response.error?.code == .cancelled)
        #expect(response.error?.retryable == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.wavURL.path))
        #expect(try Data(contentsOf: fixture.inputURL) == fixture.inputBytes)
    }

    @Test func deadlineReturnsTimeoutAndRemovesTemporaryAudio() async throws {
        let fixture = try makeFixture(timeoutSeconds: 0.2)
        let backend = SuspendingBackend()
        let bridge = makeBridge(runner: makeRunner(backend: backend, modelContext: fixture.modelContext))

        bridge.handle(invocationURL(for: fixture.requestURL))
        await backend.waitForStart()
        #expect(FileManager.default.fileExists(atPath: fixture.wavURL.path))

        let response = try await waitForResponse(at: fixture.responseURL)
        #expect(response.error?.code == .timeout)
        #expect(response.error?.retryable == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.wavURL.path))
        #expect(try Data(contentsOf: fixture.inputURL) == fixture.inputBytes)
    }

    @Test func cancellationTokenIsVisibleAcrossThreads() async throws {
        let token = TranscriptionCancellationToken()
        #expect(!token.isCancelled)
        #expect(await Task.detached { token.isCancelled }.value == false)

        await Task.detached { token.cancel() }.value

        #expect(token.isCancelled)
        #expect(await Task.detached { token.isCancelled }.value == true)
    }

    @Test func operationCompletionWinsADeadlineRace() async throws {
        let fixture = try makeFixture(timeoutSeconds: 30)
        let bridge = makeBridge(runner: makeRunner(backend: ImmediateBackend(transcript: "Готово."), modelContext: fixture.modelContext))

        bridge.handle(invocationURL(for: fixture.requestURL))

        let response = try await waitForResponse(at: fixture.responseURL)
        #expect(response.status == .success)
        #expect(response.result?.transcript == "Готово.")
        #expect(response.error == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.wavURL.path))
    }

    @Test func timeoutResponseKeepsOriginalRequestId() async throws {
        let fixture = try makeFixture(timeoutSeconds: 0.2)
        let bridge = makeBridge(runner: makeRunner(backend: SuspendingBackend(), modelContext: fixture.modelContext))

        bridge.handle(invocationURL(for: fixture.requestURL))

        let response = try await waitForResponse(at: fixture.responseURL)
        #expect(response.error?.code == .timeout)
        #expect(response.requestId == fixture.request.requestId)
        #expect(response.contractVersion == InboxCompanionContract.version)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let request: InboxCompanionRequest
        let requestURL: URL
        let responseURL: URL
        let cancellationURL: URL
        let wavURL: URL
        let inputURL: URL
        let inputBytes: Data
        let modelContext: ModelContext
    }

    private var privateRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voiceink-inbox-companion", isDirectory: true)
    }

    private func makeFixture(timeoutSeconds: Double) throws -> Fixture {
        let directory = privateRoot.appendingPathComponent("request.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("input.m4a")
        let inputBytes = Data("original input bytes".utf8)
        try inputBytes.write(to: input)
        let responseURL = directory.appendingPathComponent("response.json")
        let request = InboxCompanionRequest(
            contractVersion: InboxCompanionContract.version,
            requestId: UUID(),
            inputPath: input.path,
            promptPath: Self.trustedCompanionDirectory.appendingPathComponent("inbox-transcription-prompt.txt").path,
            responsePath: responseURL.path,
            cancellationPath: directory.appendingPathComponent("cancel").path,
            timeoutSeconds: timeoutSeconds
        )
        let requestURL = directory.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL)
        let container = try ModelContainer(for: WordReplacement.self, Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return Fixture(
            request: request,
            requestURL: requestURL,
            responseURL: responseURL,
            cancellationURL: URL(fileURLWithPath: request.cancellationPath),
            wavURL: directory.appendingPathComponent("request-audio.wav"),
            inputURL: input,
            inputBytes: inputBytes,
            modelContext: ModelContext(container)
        )
    }

    private func makeRunner(backend: any InboxTranscriptionBackend, modelContext: ModelContext) -> InboxTranscriptionRunner {
        InboxTranscriptionRunner(audioPreparer: StubAudioPreparer(), backend: backend, modelContext: modelContext)
    }

    private func makeBridge(runner: any InboxTranscriptionRunning) -> InboxCompanionBridge {
        InboxCompanionBridge(
            runner: runner,
            snapshotResolver: { _, _ in snapshot() },
            trustedCompanionDirectoryURL: Self.trustedCompanionDirectory
        )
    }

    private func invocationURL(for requestURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = InboxCompanionContract.scheme
        components.host = InboxCompanionContract.host
        components.queryItems = [URLQueryItem(name: "request", value: requestURL.path)]
        return components.url!
    }

    private func snapshot() -> InboxCompanionRuntimeSnapshot {
        let mode = ModeConfig(name: "Inbox", isAIEnhancementEnabled: false, selectedTranscriptionModelName: "inbox-whisper", selectedLanguage: "ru")
        let model = WhisperModel(name: "inbox-whisper", displayName: "Inbox Whisper", size: "test", supportedLanguages: ["ru": "Russian"], description: "test", speed: 1, accuracy: 1, ramUsage: 1)
        return InboxCompanionRuntimeSnapshot(
            mode: mode,
            transcription: TranscriptionRuntimeConfiguration(mode: mode, model: model, language: "ru", isRealtimeEnabled: false),
            formatting: TranscriptionFormattingConfiguration(mode: mode, isTextFormattingEnabled: false),
            prompt: "test",
            promptSHA256: "test",
            promptApplied: false
        )
    }

    private func waitForResponse(at url: URL) async throws -> InboxCompanionResponse {
        for _ in 0 ..< 300 {
            if let data = try? Data(contentsOf: url) {
                return try JSONDecoder().decode(InboxCompanionResponse.self, from: data)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static let trustedCompanionDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("voiceink-inbox-cancellation-companion", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("voiceink-inbox-transcribe")
        let prompt = directory.appendingPathComponent("inbox-transcription-prompt.txt")
        try! Data("#!/bin/sh\n".utf8).write(to: executable)
        try! Data("test".utf8).write(to: prompt)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prompt.path)
        return directory
    }()
}

private final class StubAudioPreparer: InboxAudioPreparing {
    func prepareReadOnlyInput(_ input: URL, wavOutput: URL) async throws -> TimeInterval {
        try Data("wav".utf8).write(to: wavOutput)
        return 1.25
    }
}

/// Suspends until the shared token flips or the task is cancelled, which is what the real
/// whisper abort callback and URLSession cancellation do at the same boundary.
@MainActor
private final class SuspendingBackend: InboxTranscriptionBackend {
    private var didStart = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    func transcribe(wavURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        didStart = true
        startContinuation?.resume()
        startContinuation = nil
        while true {
            if context.cancellation?.isCancelled == true || Task.isCancelled { throw CancellationError() }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func cleanup() async {}

    func waitForStart() async {
        if didStart { return }
        await withCheckedContinuation { startContinuation = $0 }
    }
}

@MainActor
private final class ImmediateBackend: InboxTranscriptionBackend {
    private let transcript: String
    init(transcript: String) { self.transcript = transcript }
    func transcribe(wavURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String { transcript }
    func cleanup() async {}
}
