import Darwin
import Foundation
import OSLog

// File-level so the nonisolated request-directory handle can read it without crossing
// the bridge's main-actor isolation, which Swift 6 rejects outright.
private let maximumRequestBytes = 64 * 1024

@MainActor
final class InboxCompanionBridge {
    private static let requiredRequestKeys: Set<String> = [
        "contractVersion", "requestId", "inputPath", "promptPath", "responsePath", "cancellationPath", "timeoutSeconds",
    ]
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "InboxCompanion")

    private let runner: any InboxTranscriptionRunning
    private let snapshotResolver: (InboxCompanionRequest, Data) throws -> InboxCompanionRuntimeSnapshot
    private let fileManager: FileManager
    private let trustedCompanionDirectoryURL: URL
    private var hasActiveRequest = false

    init(
        runner: any InboxTranscriptionRunning,
        snapshotResolver: @escaping (InboxCompanionRequest, Data) throws -> InboxCompanionRuntimeSnapshot,
        fileManager: FileManager = .default,
        trustedCompanionDirectoryURL: URL = InboxCompanionInstallation.directoryURL
    ) {
        self.runner = runner
        self.snapshotResolver = snapshotResolver
        self.fileManager = fileManager
        self.trustedCompanionDirectoryURL = trustedCompanionDirectoryURL.standardizedFileURL
    }

    static func isCompanionURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == InboxCompanionContract.scheme
            && url.host?.lowercased() == InboxCompanionContract.host
    }

    func handles(_ url: URL) -> Bool { Self.isCompanionURL(url) }

    func handle(_ url: URL) {
        guard handles(url) else { return }
        let invocation = invocation(for: url)
        guard let requestPath = invocation.requestPath,
              let validated = validatedRequest(at: requestPath)
        else { return }

        let request = validated.request
        guard invocation.isValid else {
            writeFailure(request, code: .invalidInvocation, phase: "invocation", retryable: false, to: validated.directory)
            return
        }
        guard request.contractVersion == InboxCompanionContract.version else {
            writeFailure(request, code: .incompatibleContract, phase: "invocation", retryable: false, to: validated.directory)
            return
        }
        guard !hasActiveRequest else {
            writeFailure(request, code: .busy, phase: "queue", retryable: true, to: validated.directory)
            return
        }

        hasActiveRequest = true
        let startedAt = ContinuousClock.now
        Task { @MainActor [weak self] in
            guard let self else { return }
            let response = await self.runBounded(request, directory: validated.directory)
            self.write(response, to: validated.directory)
            self.hasActiveRequest = false
            self.log(requestId: request.requestId, phase: "complete", code: response.error?.code, startedAt: startedAt)
        }
    }

    /// Races the transcription against the request's cancel marker and its deadline. Whichever
    /// arrives first, the losing side is unwound and its cleanup awaited so that exactly one
    /// response is written and no request-scoped audio survives.
    private func runBounded(_ request: InboxCompanionRequest, directory: RequestDirectoryHandle) async -> InboxCompanionResponse {
        let cancellation = TranscriptionCancellationToken()
        let outcome = await withTaskGroup(of: BoundedOutcome?.self, returning: BoundedOutcome.self) { group in
            group.addTask { @MainActor in BoundedOutcome.completed(await self.run(request, cancellation: cancellation)) }
            group.addTask { @MainActor in
                await Self.awaitAbort(request: request, directory: directory).map { BoundedOutcome.aborted($0) }
            }

            var settled: BoundedOutcome?
            while let next = await group.next() {
                guard let next else { continue }
                settled = next
                // Set the token before cancelling so whisper.cpp's abort callback observes it.
                if case .aborted = next { cancellation.cancel() }
                group.cancelAll()
                while await group.next() != nil {}
                break
            }
            return settled ?? .aborted(.internalFailure)
        }

        switch outcome {
        case .completed(let response):
            return response
        case .aborted(let code):
            return failure(request, code: code, phase: "transcription", retryable: code == .timeout)
        }
    }

    private static func awaitAbort(request: InboxCompanionRequest, directory: RequestDirectoryHandle) async -> InboxCompanionFailureCode? {
        let deadline = ContinuousClock.now + .seconds(request.timeoutSeconds)
        while !Task.isCancelled {
            if directory.hasCancellationMarker() { return .cancelled }
            if ContinuousClock.now >= deadline { return .timeout }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return nil }
        }
        return nil
    }

    private func run(_ request: InboxCompanionRequest, cancellation: TranscriptionCancellationToken) async -> InboxCompanionResponse {
        do {
            let promptData = try trustedStaticPromptData(for: request)
            let snapshot = try snapshotResolver(request, promptData)
            let response = await runner.run(request: request, snapshot: snapshot, cancellation: cancellation)
            guard response.requestId == request.requestId else {
                return failure(request, code: .internalFailure, phase: "transcription", retryable: false)
            }
            return response
        } catch let error as InboxCompanionPreflightError {
            return failure(request, code: error.failureCode, phase: "preflight", retryable: false)
        } catch let error as PromptTrustError {
            return failure(request, code: error.failureCode, phase: "preflight", retryable: false)
        } catch {
            return failure(request, code: .internalFailure, phase: "preflight", retryable: false)
        }
    }

    private func invocation(for url: URL) -> (requestPath: String?, isValid: Bool) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return (nil, false) }
        let requestItems = (components.queryItems ?? []).filter { $0.name == "request" }
        let requestPath = requestItems.count == 1 ? requestItems[0].value : nil
        let isValid = components.user == nil && components.password == nil && components.port == nil
            && components.path.isEmpty && components.fragment == nil
            && (components.queryItems ?? []).count == 1 && requestPath?.isEmpty == false
        return (requestPath, isValid)
    }

    private func validatedRequest(at requestPath: String) -> ValidatedRequest? {
        guard let requestURL = canonicalRequestURL(from: requestPath),
              let requestDirectoryName = directRequestDirectoryName(for: requestURL),
              let directory = try? RequestDirectoryHandle.open(rootURL: privateRootURL(), childName: requestDirectoryName),
              let requestData = try? directory.readRequest(),
              requestData.count <= maximumRequestBytes,
              hasClosedV1Schema(requestData),
              let request = try? JSONDecoder().decode(InboxCompanionRequest.self, from: requestData),
              request.responsePath == requestURL.deletingLastPathComponent().appendingPathComponent("response.json").path,
              request.cancellationPath == requestURL.deletingLastPathComponent().appendingPathComponent("cancel").path
        else { return nil }
        return ValidatedRequest(request: request, directory: directory)
    }

    private func canonicalRequestURL(from requestPath: String) -> URL? {
        guard requestPath.hasPrefix("/") else { return nil }
        let requestURL = URL(fileURLWithPath: requestPath).standardizedFileURL
        guard requestURL.path == requestPath, requestURL.lastPathComponent == "request.json" else { return nil }
        return requestURL
    }

    private func directRequestDirectoryName(for requestURL: URL) -> String? {
        let rootURL = privateRootURL()
        let directoryURL = requestURL.deletingLastPathComponent()
        guard directoryURL.deletingLastPathComponent().path == rootURL.path else { return nil }
        let name = directoryURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return name
    }

    private func privateRootURL() -> URL {
        fileManager.temporaryDirectory.appendingPathComponent("voiceink-inbox-companion", isDirectory: true).standardizedFileURL
    }

    private func hasClosedV1Schema(_ data: Data) -> Bool {
        var scanner = StrictTopLevelJSONKeys(data: data)
        guard let keys = scanner.parse(),
              keys.count == Self.requiredRequestKeys.count,
              Set(keys).count == keys.count,
              Set(keys) == Self.requiredRequestKeys,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return false }
        return Set(dictionary.keys) == Self.requiredRequestKeys
    }

    // Task 5 installs the version-controlled `Companion/` files into this fixed anchor.
    // The request path is only an equality assertion; prompt bytes are reread from the anchor descriptor per request.
    private func trustedStaticPromptData(for request: InboxCompanionRequest) throws -> Data {
        let expectedPromptURL = InboxCompanionInstallation.promptURL(in: trustedCompanionDirectoryURL)
        guard request.promptPath == expectedPromptURL.path,
              trustedCompanionDirectoryURL.resolvingSymlinksInPath().path == trustedCompanionDirectoryURL.path
        else { throw PromptTrustError.unreadable }
        let directory = try StaticPromptDirectory.open(at: trustedCompanionDirectoryURL)
        return try directory.readPrompt()
    }

    private func writeFailure(_ request: InboxCompanionRequest, code: InboxCompanionFailureCode, phase: String, retryable: Bool, to directory: RequestDirectoryHandle) {
        write(failure(request, code: code, phase: phase, retryable: retryable), to: directory)
        log(requestId: request.requestId, phase: phase, code: code, startedAt: ContinuousClock.now)
    }

    private func failure(_ request: InboxCompanionRequest, code: InboxCompanionFailureCode, phase: String, retryable: Bool) -> InboxCompanionResponse {
        .failure(requestId: request.requestId, error: InboxCompanionFailure(code: code, phase: phase, message: "Inbox companion request failed.", retryable: retryable))
    }

    private func write(_ response: InboxCompanionResponse, to directory: RequestDirectoryHandle) {
        do { try directory.writeResponse(InboxCompanionResponse.makeJSONEncoder().encode(response)) }
        catch { log(requestId: response.requestId, phase: "response", code: .internalFailure, startedAt: ContinuousClock.now) }
    }

    private func log(requestId: UUID, phase: String, code: InboxCompanionFailureCode?, startedAt: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - startedAt
        Self.logger.notice("Inbox companion request=\(requestId.uuidString, privacy: .private(mask: .hash)) phase=\(phase, privacy: .public) code=\((code?.rawValue ?? "none"), privacy: .public) elapsed=\(elapsed.components.seconds, privacy: .public)s")
    }
}

private enum BoundedOutcome {
    case completed(InboxCompanionResponse)
    case aborted(InboxCompanionFailureCode)
}

private struct ValidatedRequest {
    let request: InboxCompanionRequest
    let directory: RequestDirectoryHandle
}

private enum PromptTrustError: Error {
    case missing
    case unreadable

    var failureCode: InboxCompanionFailureCode {
        switch self {
        case .missing: .promptMissing
        case .unreadable: .promptUnreadable
        }
    }
}

// Sendable by inspection: both descriptors are immutable after init and every operation is a
// single syscall against them, so the watcher and the operation may hold it concurrently.
private final class RequestDirectoryHandle: @unchecked Sendable {
    private let rootFD: Int32
    private let directoryFD: Int32

    private init(rootFD: Int32, directoryFD: Int32) { self.rootFD = rootFD; self.directoryFD = directoryFD }
    deinit { Darwin.close(directoryFD); Darwin.close(rootFD) }

    static func open(rootURL: URL, childName: String) throws -> RequestDirectoryHandle {
        let rootFD = try openDirectory(rootURL.path, relativeTo: AT_FDCWD)
        do {
            try requirePrivateDirectory(rootFD)
            let directoryFD = try openDirectory(childName, relativeTo: rootFD)
            do {
                try requirePrivateDirectory(directoryFD)
                return RequestDirectoryHandle(rootFD: rootFD, directoryFD: directoryFD)
            } catch { Darwin.close(directoryFD); throw error }
        } catch { Darwin.close(rootFD); throw error }
    }

    func hasCancellationMarker() -> Bool {
        var status = stat()
        return "cancel".withCString { Darwin.fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW) } == 0
    }

    func readRequest() throws -> Data {
        let fd = try openRegularFile("request.json", relativeTo: directoryFD)
        defer { Darwin.close(fd) }
        return try readOwnedRegularFile(fd, maximumBytes: maximumRequestBytes)
    }

    func writeResponse(_ data: Data) throws {
        let temporaryName = ".response.\(UUID().uuidString).tmp"
        let fd = try openExclusiveOutput(temporaryName, relativeTo: directoryFD)
        var isOpen = true
        do {
            try writeAll(data, to: fd)
            guard Darwin.close(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            isOpen = false
            guard Darwin.renameat(directoryFD, temporaryName, directoryFD, "response.json") == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if isOpen { Darwin.close(fd) }
            Darwin.unlinkat(directoryFD, temporaryName, 0)
            throw error
        }
    }
}

private final class StaticPromptDirectory {
    private let directoryFD: Int32
    private init(directoryFD: Int32) { self.directoryFD = directoryFD }
    deinit { Darwin.close(directoryFD) }

    static func open(at url: URL) throws -> StaticPromptDirectory {
        let fd: Int32
        do { fd = try openDirectory(url.path, relativeTo: AT_FDCWD) }
        catch let error as POSIXError where error.code == .ENOENT { throw PromptTrustError.missing }
        catch { throw PromptTrustError.unreadable }
        do {
            try requirePrivateDirectory(fd)
            try requireOwnedExecutable("voiceink-inbox-transcribe", relativeTo: fd)
            return StaticPromptDirectory(directoryFD: fd)
        } catch { Darwin.close(fd); throw PromptTrustError.unreadable }
    }

    func readPrompt() throws -> Data {
        let fd: Int32
        do { fd = try openRegularFile("inbox-transcription-prompt.txt", relativeTo: directoryFD) }
        catch let error as POSIXError where error.code == .ENOENT { throw PromptTrustError.missing }
        catch { throw PromptTrustError.unreadable }
        defer { Darwin.close(fd) }
        do { return try readOwnedTrustedFile(fd, maximumBytes: 1_048_576) }
        catch { throw PromptTrustError.unreadable }
    }
}

private func openDirectory(_ path: String, relativeTo directoryFD: Int32) throws -> Int32 {
    let fd = path.withCString { Darwin.openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return fd
}

private func openRegularFile(_ name: String, relativeTo directoryFD: Int32) throws -> Int32 {
    let fd = name.withCString { Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return fd
}

private func openExclusiveOutput(_ name: String, relativeTo directoryFD: Int32) throws -> Int32 {
    let fd = name.withCString { Darwin.openat(directoryFD, $0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR)) }
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return fd
}

private func requirePrivateDirectory(_ fd: Int32) throws {
    try requireOwnedDirectory(fd)
    var status = stat()
    guard Darwin.fstat(fd, &status) == 0,
          (mode_t(status.st_mode) & (mode_t(S_IWGRP) | mode_t(S_IWOTH))) == 0
    else { throw POSIXError(.EPERM) }
}

private func requireOwnedDirectory(_ fd: Int32) throws {
    var status = stat()
    guard Darwin.fstat(fd, &status) == 0,
          (mode_t(status.st_mode) & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          status.st_uid == getuid()
    else { throw POSIXError(.EPERM) }
}

private func requireOwnedExecutable(_ name: String, relativeTo directoryFD: Int32) throws {
    var status = stat()
    let result = name.withCString { Darwin.fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW) }
    guard result == 0,
          (mode_t(status.st_mode) & mode_t(S_IFMT)) == mode_t(S_IFREG),
          status.st_uid == getuid(),
          (mode_t(status.st_mode) & mode_t(S_IXUSR)) != 0,
          (mode_t(status.st_mode) & (mode_t(S_IWGRP) | mode_t(S_IWOTH))) == 0
    else { throw POSIXError(.EPERM) }
}

private func readOwnedRegularFile(_ fd: Int32, maximumBytes: Int) throws -> Data {
    var status = stat()
    guard Darwin.fstat(fd, &status) == 0,
          (mode_t(status.st_mode) & mode_t(S_IFMT)) == mode_t(S_IFREG),
          status.st_uid == getuid(),
          status.st_size >= 0, status.st_size <= off_t(maximumBytes)
    else { throw POSIXError(.EPERM) }
    var data = Data(count: Int(status.st_size))
    var total = 0
    try data.withUnsafeMutableBytes { buffer in
        while total < buffer.count {
            let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total)
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            total += count
        }
    }
    return data
}

private func readOwnedTrustedFile(_ fd: Int32, maximumBytes: Int) throws -> Data {
    var status = stat()
    guard Darwin.fstat(fd, &status) == 0,
          (mode_t(status.st_mode) & mode_t(S_IFMT)) == mode_t(S_IFREG),
          status.st_uid == getuid(),
          (mode_t(status.st_mode) & (mode_t(S_IWGRP) | mode_t(S_IWOTH))) == 0
    else { throw POSIXError(.EPERM) }
    return try readOwnedRegularFile(fd, maximumBytes: maximumBytes)
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    var total = 0
    try data.withUnsafeBytes { buffer in
        while total < buffer.count {
            let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total)
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            total += count
        }
    }
}
