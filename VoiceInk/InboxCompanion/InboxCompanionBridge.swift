import Darwin
import Foundation
import OSLog

@MainActor
final class InboxCompanionBridge {
    fileprivate static let maximumRequestBytes = 64 * 1024
    private static let requiredRequestKeys: Set<String> = [
        "contractVersion", "requestId", "inputPath", "promptPath", "responsePath", "cancellationPath", "timeoutSeconds",
    ]
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "InboxCompanion")

    private let runner: any InboxTranscriptionRunning
    private let snapshotResolver: (InboxCompanionRequest, Data) throws -> InboxCompanionRuntimeSnapshot
    private let fileManager: FileManager
    private var hasActiveRequest = false

    init(
        runner: any InboxTranscriptionRunning,
        snapshotResolver: @escaping (InboxCompanionRequest, Data) throws -> InboxCompanionRuntimeSnapshot,
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.snapshotResolver = snapshotResolver
        self.fileManager = fileManager
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
            let response = await self.run(request, promptData: validated.promptData)
            self.write(response, to: validated.directory)
            self.hasActiveRequest = false
            self.log(requestId: request.requestId, phase: "complete", code: response.error?.code, startedAt: startedAt)
        }
    }

    private func run(_ request: InboxCompanionRequest, promptData: Data) async -> InboxCompanionResponse {
        do {
            let snapshot = try snapshotResolver(request, promptData)
            let response = await runner.run(request: request, snapshot: snapshot, cancellation: TranscriptionCancellationToken())
            guard response.requestId == request.requestId else {
                return failure(request, code: .internalFailure, phase: "transcription", retryable: false)
            }
            return response
        } catch let error as InboxCompanionPreflightError {
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
              requestData.count <= Self.maximumRequestBytes,
              hasClosedV1Schema(requestData),
              let request = try? JSONDecoder().decode(InboxCompanionRequest.self, from: requestData),
              request.responsePath == requestURL.deletingLastPathComponent().appendingPathComponent("response.json").path,
              request.cancellationPath == requestURL.deletingLastPathComponent().appendingPathComponent("cancel").path,
              let promptData = trustedStaticPromptData(at: request.promptPath)
        else { return nil }
        return ValidatedRequest(request: request, promptData: promptData, directory: directory)
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
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return false }
        return Set(dictionary.keys) == Self.requiredRequestKeys
    }

    // The CLI uses `pwd -P` and makes these two version-controlled sibling files the request's prompt authority.
    // Their descriptors are checked and read here so preflight never reopens a caller-selected prompt pathname.
    private func trustedStaticPromptData(at promptPath: String) -> Data? {
        guard promptPath.hasPrefix("/") else { return nil }
        let promptURL = URL(fileURLWithPath: promptPath).standardizedFileURL
        guard promptURL.path == promptPath,
              promptURL.lastPathComponent == "inbox-transcription-prompt.txt",
              promptURL.resolvingSymlinksInPath().path == promptURL.path,
              let directory = try? StaticPromptDirectory.open(at: promptURL.deletingLastPathComponent()),
              let data = try? directory.readPrompt()
        else { return nil }
        return data
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

private struct ValidatedRequest {
    let request: InboxCompanionRequest
    let promptData: Data
    let directory: RequestDirectoryHandle
}

private final class RequestDirectoryHandle {
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

    func readRequest() throws -> Data {
        let fd = try openRegularFile("request.json", relativeTo: directoryFD)
        defer { Darwin.close(fd) }
        return try readOwnedRegularFile(fd, maximumBytes: InboxCompanionBridge.maximumRequestBytes)
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
        let fd = try openDirectory(url.path, relativeTo: AT_FDCWD)
        do {
            try requireOwnedDirectory(fd)
            try requireOwnedExecutable("voiceink-inbox-transcribe", relativeTo: fd)
            return StaticPromptDirectory(directoryFD: fd)
        } catch { Darwin.close(fd); throw error }
    }

    func readPrompt() throws -> Data {
        let fd = try openRegularFile("inbox-transcription-prompt.txt", relativeTo: directoryFD)
        defer { Darwin.close(fd) }
        return try readOwnedRegularFile(fd, maximumBytes: 1_048_576)
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
          (mode_t(status.st_mode) & mode_t(S_IXUSR)) != 0
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
