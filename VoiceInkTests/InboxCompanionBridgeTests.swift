import AppKit
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

    @Test func mixedURLsPreserveNormalURLs() {
        let companion = URL(string: "voiceink-inbox://transcribe?request=/tmp/request.json")!
        let normal = URL(fileURLWithPath: "/tmp/recording.m4a")
        let partition = AppDelegate.partitionOpenURLs([companion, normal])
        #expect(partition.companion == [companion])
        #expect(partition.remaining == [normal])
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
    }

    @Test func symlinkedRequestFileIsRejected() async throws {
        let fixture = try makeRequest()
        let target = fixture.requestURL.deletingLastPathComponent().appendingPathComponent("other.json")
        try FileManager.default.copyItem(at: fixture.requestURL, to: target)
        try FileManager.default.removeItem(at: fixture.requestURL)
        try FileManager.default.createSymbolicLink(at: fixture.requestURL, withDestinationURL: target)
        let runner = FakeRunner(response: successResponse(for: fixture.request))
        let bridge = makeBridge(runner: runner)
        bridge.handle(invocationURL(for: fixture.requestURL))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runner.didRun)
        #expect(!FileManager.default.fileExists(atPath: fixture.responseURL.path))
    }

    @Test func oversizedRequestIsRejected() async throws {
        let fixture = try makeRequest()
        try Data(repeating: 0x20, count: 64 * 1024 + 1).write(to: fixture.requestURL)
        let runner = FakeRunner(response: successResponse(for: fixture.request))
        let bridge = makeBridge(runner: runner)
        bridge.handle(invocationURL(for: fixture.requestURL))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runner.didRun)
        #expect(!FileManager.default.fileExists(atPath: fixture.responseURL.path))
    }

    @Test func surplusRequestKeysAreRejected() async throws {
        let fixture = try makeRequest()
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.requestURL)) as! [String: Any]
        object["surplus"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.requestURL)
        let runner = FakeRunner(response: successResponse(for: fixture.request))
        let bridge = makeBridge(runner: runner)
        bridge.handle(invocationURL(for: fixture.requestURL))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runner.didRun)
        #expect(!FileManager.default.fileExists(atPath: fixture.responseURL.path))
    }

    @Test func duplicateTopLevelRequestKeyIsRejected() async throws {
        let fixture = try makeRequest()
        let original = try Data(contentsOf: fixture.requestURL)
        var duplicate = Data("{\"requestId\":\"\(UUID().uuidString)\",".utf8)
        duplicate.append(contentsOf: original.dropFirst())
        try duplicate.write(to: fixture.requestURL)
        let runner = FakeRunner(response: successResponse(for: fixture.request))
        let bridge = makeBridge(runner: runner)
        bridge.handle(invocationURL(for: fixture.requestURL))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runner.didRun)
        #expect(!FileManager.default.fileExists(atPath: fixture.responseURL.path))
    }

    @Test func deeplyNestedRequestValueIsRejected() async throws {
        let fixture = try makeRequest()
        let depth = 30_000
        var payload = Data("{\"contractVersion\":".utf8)
        payload.append(Data(repeating: 0x5B, count: depth))
        payload.append(Data(repeating: 0x5D, count: depth))
        payload.append(Data("}".utf8))
        #expect(payload.count <= 64 * 1024)
        try payload.write(to: fixture.requestURL)
        let runner = FakeRunner(response: successResponse(for: fixture.request))
        let bridge = makeBridge(runner: runner)
        bridge.handle(invocationURL(for: fixture.requestURL))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!runner.didRun)
        #expect(!FileManager.default.fileExists(atPath: fixture.responseURL.path))
    }

    @Test func mismatchedPromptPathProducesAssociatedFailure() async throws {
        let fixture = try makeRequest(promptURL: privateRoot.appendingPathComponent("other-prompt.txt"))
        try Data("test".utf8).write(to: URL(fileURLWithPath: fixture.request.promptPath))
        let runner = FakeRunner(response: successResponse(for: fixture.request))
        let bridge = makeBridge(runner: runner)
        bridge.handle(invocationURL(for: fixture.requestURL))
        let response = try await waitForResponse(at: fixture.responseURL)
        #expect(!runner.didRun)
        #expect(response.requestId == fixture.request.requestId)
        #expect(response.error?.code == .promptUnreadable)
    }

    @Test func missingTrustedPromptProducesAssociatedFailure() async throws {
        let fixture = try makeRequest()
        try FileManager.default.removeItem(at: Self.trustedCompanionDirectory.appendingPathComponent("inbox-transcription-prompt.txt"))
        let bridge = makeBridge(runner: FakeRunner(response: successResponse(for: fixture.request)))
        bridge.handle(invocationURL(for: fixture.requestURL))
        let response = try await waitForResponse(at: fixture.responseURL)
        #expect(response.requestId == fixture.request.requestId)
        #expect(response.error?.code == .promptMissing)
    }

    @Test func unsafeTrustedPromptProducesAssociatedFailure() async throws {
        let fixture = try makeRequest()
        let prompt = Self.trustedCompanionDirectory.appendingPathComponent("inbox-transcription-prompt.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o620], ofItemAtPath: prompt.path)
        let bridge = makeBridge(runner: FakeRunner(response: successResponse(for: fixture.request)))
        bridge.handle(invocationURL(for: fixture.requestURL))
        let response = try await waitForResponse(at: fixture.responseURL)
        #expect(response.requestId == fixture.request.requestId)
        #expect(response.error?.code == .promptUnreadable)
    }

    @Test func successfulResponseIsWrittenAtomicallyToAssociatedPath() async throws {
        let fixture = try makeRequest()
        let expected = successResponse(for: fixture.request)
        let bridge = makeBridge(runner: FakeRunner(response: expected))
        bridge.handle(invocationURL(for: fixture.requestURL))
        let response = try await waitForResponse(at: fixture.responseURL)
        #expect(response.status == .success)
        #expect(response.result == expected.result)
        #expect(response.error == nil)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.responseURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".response.") && $0.hasSuffix(".tmp") }
        #expect(temporaryFiles.isEmpty)
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

    @Test func queuedRequestsReceiveResponsesOrBusy() async throws {
        let first = try makeRequest()
        let second = try makeRequest()
        let runner = BlockingRunner(response: successResponse(for: first.request))
        let bridge = makeBridge(runner: runner)
        let delegate = AppDelegate()
        delegate.application(NSApplication.shared, open: [invocationURL(for: first.requestURL), invocationURL(for: second.requestURL)])
        delegate.configureInboxCompanionBridge(bridge)
        await runner.waitForStart()
        #expect(try await waitForResponse(at: second.responseURL).error?.code == .busy)
        runner.release()
        _ = try await waitForResponse(at: first.responseURL)
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

    private func makeBridge(runner: (any InboxTranscriptionRunning)? = nil, trustedDirectory: URL? = nil) -> InboxCompanionBridge {
        InboxCompanionBridge(
            runner: runner ?? FakeRunner(response: .failure(requestId: UUID(), error: InboxCompanionFailure(code: .internalFailure, phase: "test", message: "test", retryable: false))),
            snapshotResolver: { _, _ in snapshot() },
            trustedCompanionDirectoryURL: trustedDirectory ?? Self.trustedCompanionDirectory
        )
    }

    private func makeRequest(directory: URL? = nil, responseURL: URL? = nil, promptURL: URL? = nil) throws -> (request: InboxCompanionRequest, requestURL: URL, responseURL: URL) {
        let directory = directory ?? privateRoot.appendingPathComponent("request.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let responseURL = responseURL ?? directory.appendingPathComponent("response.json")
        let promptURL = promptURL ?? try makeTrustedPrompt()
        let request = InboxCompanionRequest(
            contractVersion: InboxCompanionContract.version,
            requestId: UUID(),
            inputPath: directory.appendingPathComponent("input.m4a").path,
            promptPath: promptURL.path,
            responsePath: responseURL.path,
            cancellationPath: directory.appendingPathComponent("cancel").path,
            timeoutSeconds: 30
        )
        let requestURL = directory.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL)
        return (request, requestURL, responseURL)
    }

    private func makeTrustedPrompt() throws -> URL {
        let executable = Self.trustedCompanionDirectory.appendingPathComponent("voiceink-inbox-transcribe")
        let prompt = Self.trustedCompanionDirectory.appendingPathComponent("inbox-transcription-prompt.txt")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try Data("test".utf8).write(to: prompt)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prompt.path)
        return prompt
    }

    private func invocationURL(for requestURL: URL, suffix: String = "") -> URL {
        var components = URLComponents()
        components.scheme = InboxCompanionContract.scheme
        components.host = InboxCompanionContract.host
        components.queryItems = [URLQueryItem(name: "request", value: requestURL.path)]
        return URL(string: components.url!.absoluteString + suffix)!
    }

    private func successResponse(for request: InboxCompanionRequest) -> InboxCompanionResponse {
        let mode = InboxCompanionModeIdentity(id: UUID(), name: "Inbox")
        let model = InboxCompanionModelIdentity(name: "inbox-whisper", displayName: "Inbox Whisper", provider: "whisper")
        return .success(requestId: request.requestId, result: InboxCompanionSuccess(transcript: "completed", mode: mode, model: model, language: "en", mediaDurationSeconds: 1, execution: .local, prompt: InboxCompanionPromptMetadata(applied: true, sha256: "test"), aiEnhancementApplied: false))
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

    private static let trustedCompanionDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("voiceink-inbox-test-companion", isDirectory: true)
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

@MainActor
private final class FakeRunner: InboxTranscriptionRunning {
    let response: InboxCompanionResponse
    private(set) var didRun = false
    init(response: InboxCompanionResponse) { self.response = response }
    func run(request: InboxCompanionRequest, snapshot: InboxCompanionRuntimeSnapshot, cancellation: TranscriptionCancellationToken) async -> InboxCompanionResponse { didRun = true; return response }
}

@MainActor
private final class BlockingRunner: InboxTranscriptionRunning {
    let response: InboxCompanionResponse
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    init(response: InboxCompanionResponse) { self.response = response }
    func run(request: InboxCompanionRequest, snapshot: InboxCompanionRuntimeSnapshot, cancellation: TranscriptionCancellationToken) async -> InboxCompanionResponse {
        didStart = true; startContinuation?.resume(); startContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
        return response
    }
    func waitForStart() async { if !didStart { await withCheckedContinuation { startContinuation = $0 } } }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

@MainActor
private final class MainWindowRequestObserver { var count = 0 }
