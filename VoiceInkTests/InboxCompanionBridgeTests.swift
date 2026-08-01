import Foundation
import Testing

@testable import VoiceInk

@Suite(.serialized)
@MainActor
struct InboxCompanionBridgeTests {
    @Test func unrelatedURLsAreNotHandled() {
        let bridge = makeBridge()
        #expect(!bridge.handles(URL(string: "https://example.com/transcribe")!))
        #expect(!bridge.handles(URL(string: "voiceink-inbox://other?request=/tmp/request.json")!))
    }

    @Test func malformedInvocationProducesInvalidInvocationWhenRequestIdIsRecoverable() async throws {
        let fixture = try makeRequest()
        let bridge = makeBridge()
        bridge.handle(invocationURL(for: fixture.requestURL, suffix: "&unexpected=value"))
        #expect(try await waitForResponse(at: fixture.responseURL).error?.code == .invalidInvocation)
    }

    @Test func requestOutsidePrivateTempRootIsRejected() async throws {
        let fixture = try makeRequest(directory: FileManager.default.temporaryDirectory.appendingPathComponent("outside-inbox-\(UUID().uuidString)", isDirectory: true))
        let runner = FakeRunner(response: successResponse(for: fixture.request))
        let bridge = makeBridge(runner: runner)
        bridge.handle(invocationURL(for: fixture.requestURL))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runner.didRun)
        #expect(!FileManager.default.fileExists(atPath: fixture.responseURL.path))
    }

    @Test func responsePathOutsideRequestDirectoryIsRejected() async throws {
        let fixture = try makeRequest(responseURL: privateRoot.appendingPathComponent("response-\(UUID().uuidString).json"))
        let runner = FakeRunner(response: successResponse(for: fixture.request))
        let bridge = makeBridge(runner: runner)
        bridge.handle(invocationURL(for: fixture.requestURL))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runner.didRun)
        #expect(!FileManager.default.fileExists(atPath: fixture.request.responsePath))
    }

    @Test func symlinkedRequestDirectoryIsRejected() async throws {
        let actualDirectory = privateRoot.appendingPathComponent("actual-\(UUID().uuidString)", isDirectory: true)
        let fixture = try makeRequest(directory: actualDirectory)
        let symlinkDirectory = privateRoot.appendingPathComponent("linked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkDirectory, withDestinationURL: actualDirectory)
        let runner = FakeRunner(response: successResponse(for: fixture.request))
        let bridge = makeBridge(runner: runner)
        bridge.handle(invocationURL(for: symlinkDirectory.appendingPathComponent("request.json")))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runner.didRun)
        #expect(!FileManager.default.fileExists(atPath: fixture.responseURL.path))
    }

    @Test func successfulResponseIsWrittenAtomicallyToAssociatedPath() async throws {
        let fixture = try makeRequest()
        let expected = successResponse(for: fixture.request)
        let bridge = makeBridge(runner: FakeRunner(response: expected))
        bridge.handle(invocationURL(for: fixture.requestURL))
        let data = try await waitForFile(at: fixture.responseURL)
        #expect(try JSONDecoder().decode(InboxCompanionResponse.self, from: data) == expected)
        #expect(!FileManager.default.fileExists(atPath: fixture.responseURL.deletingLastPathComponent().appendingPathComponent("response.json.tmp").path))
    }

    @Test func overlappingRequestGetsBusyAtItsOwnResponsePath() async throws {
        let first = try makeRequest()
        let second = try makeRequest()
        let runner = BlockingRunner(response: successResponse(for: first.request))
        let bridge = makeBridge(runner: runner)
        bridge.handle(invocationURL(for: first.requestURL))
        await runner.waitForStart()
        bridge.handle(invocationURL(for: second.requestURL))
        #expect(try await waitForResponse(at: second.responseURL).error?.code == .busy)
        runner.release()
        #expect(try await waitForResponse(at: first.responseURL) == successResponse(for: first.request))
    }

    @Test func bridgeDoesNotPresentOrActivateVoiceInkUI() async throws {
        let fixture = try makeRequest()
        let bridge = makeBridge(runner: FakeRunner(response: successResponse(for: fixture.request)))
        let observer = MainWindowRequestObserver()
        let token = NotificationCenter.default.addObserver(forName: .showMainWindowRequested, object: nil, queue: nil) { _ in
            Task { @MainActor in observer.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        bridge.handle(invocationURL(for: fixture.requestURL))
        _ = try await waitForResponse(at: fixture.responseURL)
        await Task.yield()
        #expect(observer.count == 0)
    }

    private var privateRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voiceink-inbox-companion", isDirectory: true)
    }

    private func makeBridge(runner: (any InboxTranscriptionRunning)? = nil) -> InboxCompanionBridge {
        InboxCompanionBridge(
            runner: runner ?? FakeRunner(response: .failure(requestId: UUID(), error: InboxCompanionFailure(code: .internalFailure, phase: "test", message: "test", retryable: false))),
            snapshotResolver: { _ in snapshot() }
        )
    }

    private func makeRequest(directory: URL? = nil, responseURL: URL? = nil) throws -> (request: InboxCompanionRequest, requestURL: URL, responseURL: URL) {
        let directory = directory ?? privateRoot.appendingPathComponent("request.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let responseURL = responseURL ?? directory.appendingPathComponent("response.json")
        let request = InboxCompanionRequest(
            contractVersion: InboxCompanionContract.version,
            requestId: UUID(),
            inputPath: directory.appendingPathComponent("input.m4a").path,
            promptPath: directory.appendingPathComponent("prompt.txt").path,
            responsePath: responseURL.path,
            cancellationPath: directory.appendingPathComponent("cancel").path,
            timeoutSeconds: 30
        )
        let requestURL = directory.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL)
        return (request, requestURL, responseURL)
    }

    private func invocationURL(for requestURL: URL, suffix: String = "") -> URL {
        var components = URLComponents()
        components.scheme = InboxCompanionContract.scheme
        components.host = InboxCompanionContract.host
        components.queryItems = [URLQueryItem(name: "request", value: requestURL.path)]
        return URL(string: components.url!.absoluteString + suffix)!
    }

    private func successResponse(for request: InboxCompanionRequest) -> InboxCompanionResponse {
        .failure(requestId: request.requestId, error: InboxCompanionFailure(code: .internalFailure, phase: "test", message: "test", retryable: false))
    }

    private func snapshot() -> InboxCompanionRuntimeSnapshot {
        let mode = ModeConfig(name: "Inbox", isAIEnhancementEnabled: false, selectedTranscriptionModelName: "inbox-whisper", selectedLanguage: "en")
        let model = WhisperModel(name: "inbox-whisper", displayName: "Inbox Whisper", size: "test", supportedLanguages: ["en": "English"], description: "test", speed: 1, accuracy: 1, ramUsage: 1)
        return InboxCompanionRuntimeSnapshot(mode: mode, transcription: TranscriptionRuntimeConfiguration(mode: mode, model: model, language: "en", isRealtimeEnabled: false), formatting: TranscriptionFormattingConfiguration(mode: mode, isTextFormattingEnabled: false), prompt: "test", promptSHA256: "test", promptApplied: false)
    }

    private func waitForResponse(at url: URL) async throws -> InboxCompanionResponse {
        try JSONDecoder().decode(InboxCompanionResponse.self, from: await waitForFile(at: url))
    }

    private func waitForFile(at url: URL) async throws -> Data {
        for _ in 0 ..< 100 {
            if let data = try? Data(contentsOf: url) { return data }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

@MainActor
private final class FakeRunner: InboxTranscriptionRunning {
    let response: InboxCompanionResponse
    private(set) var didRun = false
    init(response: InboxCompanionResponse) { self.response = response }
    func run(request: InboxCompanionRequest, snapshot: InboxCompanionRuntimeSnapshot, cancellation: TranscriptionCancellationToken) async -> InboxCompanionResponse {
        didRun = true
        return response
    }
}

@MainActor
private final class BlockingRunner: InboxTranscriptionRunning {
    let response: InboxCompanionResponse
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    init(response: InboxCompanionResponse) { self.response = response }
    func run(request: InboxCompanionRequest, snapshot: InboxCompanionRuntimeSnapshot, cancellation: TranscriptionCancellationToken) async -> InboxCompanionResponse {
        didStart = true
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
        return response
    }
    func waitForStart() async {
        if didStart { return }
        await withCheckedContinuation { startContinuation = $0 }
    }
    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class MainWindowRequestObserver { var count = 0 }
