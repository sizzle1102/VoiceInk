import Foundation
import SwiftData
import Testing

@testable import VoiceInk

@Suite(.serialized)
@MainActor
struct InboxTranscriptionRunnerTests {
    @Test func runnerReturnsCleanedTextWithoutCreatingTranscription() async throws {
        let fixture = try makeFixture()
        let backend = FakeBackend(result: .success("  um Привет [noise] voice ink.  "))
        let runner = InboxTranscriptionRunner(audioPreparer: FakeAudioPreparer(), backend: backend, modelContext: fixture.modelContext)
        fixture.modelContext.insert(WordReplacement(originalText: "voice ink", replacementText: "VoiceInk", isEnabled: true))

        let response = await runner.run(request: fixture.request, snapshot: fixture.snapshot, cancellation: TranscriptionCancellationToken())

        #expect(response.status == .success)
        #expect(response.result?.transcript == "Привет VoiceInk.")
        let transcriptions = try fixture.modelContext.fetch(FetchDescriptor<Transcription>())
        #expect(transcriptions.isEmpty)
    }

    @Test func runnerUsesRequestScopedWAVAndDeletesItAfterSuccess() async throws {
        let fixture = try makeFixture()
        let audio = FakeAudioPreparer()
        let runner = InboxTranscriptionRunner(audioPreparer: audio, backend: FakeBackend(result: .success("Hello.")), modelContext: fixture.modelContext)

        let response = await runner.run(request: fixture.request, snapshot: fixture.snapshot, cancellation: TranscriptionCancellationToken())

        #expect(response.status == .success)
        #expect(audio.wavOutput?.deletingLastPathComponent() == fixture.requestDirectory)
        #expect(audio.wavOutput?.lastPathComponent == "request-audio.wav")
        #expect(audio.wavOutput.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func runnerDeletesTemporaryWAVAfterProviderFailure() async throws {
        let fixture = try makeFixture()
        let audio = FakeAudioPreparer()
        let runner = InboxTranscriptionRunner(audioPreparer: audio, backend: FakeBackend(result: .failure(TestError.provider)), modelContext: fixture.modelContext)

        let response = await runner.run(request: fixture.request, snapshot: fixture.snapshot, cancellation: TranscriptionCancellationToken())

        #expect(response.error?.code == .providerFailure)
        #expect(audio.wavOutput.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func runnerReportsEmptyTranscriptAsFailure() async throws {
        let fixture = try makeFixture()
        let runner = InboxTranscriptionRunner(audioPreparer: FakeAudioPreparer(), backend: FakeBackend(result: .success(" [noise] ")), modelContext: fixture.modelContext)

        let response = await runner.run(request: fixture.request, snapshot: fixture.snapshot, cancellation: TranscriptionCancellationToken())

        #expect(response.error?.code == .emptyTranscript)
    }

    @Test func runnerMapsAuthenticationRateLimitAndNetworkFailuresDistinctly() async throws {
        let fixture = try makeFixture()
        let runner = InboxTranscriptionRunner(audioPreparer: FakeAudioPreparer(), backend: FakeBackend(result: .failure(CloudTranscriptionError.invalidAPIKey)), modelContext: fixture.modelContext)
        let authentication = await runner.run(request: fixture.request, snapshot: fixture.snapshot, cancellation: TranscriptionCancellationToken())
        #expect(authentication.error?.code == .authenticationFailed)

        let rateLimitRunner = InboxTranscriptionRunner(audioPreparer: FakeAudioPreparer(), backend: FakeBackend(result: .failure(CloudTranscriptionError.apiRequestFailed(statusCode: 429, message: "slow down"))), modelContext: fixture.modelContext)
        let rateLimit = await rateLimitRunner.run(request: fixture.request, snapshot: fixture.snapshot, cancellation: TranscriptionCancellationToken())
        #expect(rateLimit.error?.code == .rateLimited)

        let networkRunner = InboxTranscriptionRunner(audioPreparer: FakeAudioPreparer(), backend: FakeBackend(result: .failure(CloudTranscriptionError.networkError(URLError(.notConnectedToInternet)))), modelContext: fixture.modelContext)
        let network = await networkRunner.run(request: fixture.request, snapshot: fixture.snapshot, cancellation: TranscriptionCancellationToken())
        #expect(network.error?.code == .networkFailure)
    }

    @Test func runnerNeverWritesToRecordingsDirectory() async throws {
        let fixture = try makeFixture()
        let recordingsDirectory = fixture.requestDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: recordingsDirectory.path)
        let runner = InboxTranscriptionRunner(audioPreparer: FakeAudioPreparer(), backend: FakeBackend(result: .success("Hello.")), modelContext: fixture.modelContext)

        _ = await runner.run(request: fixture.request, snapshot: fixture.snapshot, cancellation: TranscriptionCancellationToken())

        #expect(try FileManager.default.contentsOfDirectory(atPath: recordingsDirectory.path) == before)
    }

    @Test func runnerLeavesInputBytesUnchanged() async throws {
        let fixture = try makeFixture()
        let before = try Data(contentsOf: URL(fileURLWithPath: fixture.request.inputPath))
        let runner = InboxTranscriptionRunner(audioPreparer: FakeAudioPreparer(), backend: FakeBackend(result: .success("Hello.")), modelContext: fixture.modelContext)

        _ = await runner.run(request: fixture.request, snapshot: fixture.snapshot, cancellation: TranscriptionCancellationToken())

        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.request.inputPath)) == before)
    }

    private func makeFixture() throws -> (request: InboxCompanionRequest, requestDirectory: URL, snapshot: InboxCompanionRuntimeSnapshot, modelContext: ModelContext) {
        let requestDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
        let input = requestDirectory.appendingPathComponent("input.m4a")
        try Data("original input bytes".utf8).write(to: input)
        let mode = ModeConfig(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Inbox",
            isAIEnhancementEnabled: false,
            selectedTranscriptionModelName: "inbox-whisper",
            selectedLanguage: "ru",
            isTextFormattingEnabled: true
        )
        let model = WhisperModel(
            name: "inbox-whisper",
            displayName: "Inbox Whisper",
            size: "test",
            supportedLanguages: ["en": "English", "ru": "Russian"],
            description: "Test Whisper model",
            speed: 1,
            accuracy: 1,
            ramUsage: 1
        )
        let container = try ModelContainer(for: WordReplacement.self, Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        return (
            InboxCompanionRequest(
                contractVersion: InboxCompanionContract.version,
                requestId: UUID(),
                inputPath: input.path,
                promptPath: requestDirectory.appendingPathComponent("prompt.txt").path,
                responsePath: requestDirectory.appendingPathComponent("response.json").path,
                cancellationPath: requestDirectory.appendingPathComponent("cancel").path,
                timeoutSeconds: 30
            ),
            requestDirectory,
            InboxCompanionRuntimeSnapshot(
                mode: mode,
                transcription: TranscriptionRuntimeConfiguration(mode: mode, model: model, language: "ru", isRealtimeEnabled: false),
                formatting: TranscriptionFormattingConfiguration(mode: mode, isTextFormattingEnabled: true),
                prompt: "inbox prompt",
                promptSHA256: "e05be0d2af992ec33298fc4a883ff1477d6cec6e4fd247ae030e29346b7b8e1e",
                promptApplied: true
            ),
            context
        )
    }
}

private final class FakeAudioPreparer: InboxAudioPreparing {
    private(set) var wavOutput: URL?

    func prepareReadOnlyInput(_ input: URL, wavOutput: URL) async throws -> TimeInterval {
        self.wavOutput = wavOutput
        try Data("wav".utf8).write(to: wavOutput)
        return 1.25
    }
}

@MainActor
private final class FakeBackend: InboxTranscriptionBackend {
    let result: Result<String, Error>

    init(result: Result<String, Error>) {
        self.result = result
    }

    func transcribe(wavURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        try result.get()
    }

    func cleanup() async {}
}

private enum TestError: Error {
    case provider
}
