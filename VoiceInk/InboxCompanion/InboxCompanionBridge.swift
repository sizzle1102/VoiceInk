import Darwin
import Foundation
import OSLog

@MainActor
final class InboxCompanionBridge {
    private static let maximumRequestBytes = 64 * 1024
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "InboxCompanion")

    private let runner: any InboxTranscriptionRunning
    private let snapshotResolver: (InboxCompanionRequest) throws -> InboxCompanionRuntimeSnapshot
    private let fileManager: FileManager
    private var hasActiveRequest = false

    init(
        runner: any InboxTranscriptionRunning,
        snapshotResolver: @escaping (InboxCompanionRequest) throws -> InboxCompanionRuntimeSnapshot,
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
            writeFailure(request, code: .invalidInvocation, phase: "invocation", retryable: false, to: validated.responseURL)
            return
        }
        guard request.contractVersion == InboxCompanionContract.version else {
            writeFailure(request, code: .incompatibleContract, phase: "invocation", retryable: false, to: validated.responseURL)
            return
        }
        guard !hasActiveRequest else {
            writeFailure(request, code: .busy, phase: "queue", retryable: true, to: validated.responseURL)
            return
        }

        hasActiveRequest = true
        let startedAt = ContinuousClock.now
        Task { @MainActor [weak self] in
            guard let self else { return }
            let response = await self.run(request)
            self.write(response, to: validated.responseURL)
            self.hasActiveRequest = false
            self.log(requestId: request.requestId, phase: "complete", code: response.error?.code, startedAt: startedAt)
        }
    }

    private func run(_ request: InboxCompanionRequest) async -> InboxCompanionResponse {
        do {
            let snapshot = try snapshotResolver(request)
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
        let isValid = components.user == nil
            && components.password == nil
            && components.port == nil
            && components.path.isEmpty
            && components.fragment == nil
            && (components.queryItems ?? []).count == 1
            && requestPath?.isEmpty == false
        return (requestPath, isValid)
    }

    private func validatedRequest(at requestPath: String) -> ValidatedRequest? {
        guard requestPath.hasPrefix("/") else { return nil }
        let requestURL = URL(fileURLWithPath: requestPath)
        let rootURL = privateRootURL()
        let canonicalRequestURL = requestURL.standardizedFileURL.resolvingSymlinksInPath()
        guard isDescendant(canonicalRequestURL, of: rootURL.resolvingSymlinksInPath()),
              requestURL.lastPathComponent == "request.json",
              isSecureRequestPath(requestURL, rootURL: rootURL),
              requestByteCount(at: requestURL) <= Int64(Self.maximumRequestBytes),
              let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(InboxCompanionRequest.self, from: data)
        else { return nil }

        let requestDirectory = requestURL.deletingLastPathComponent()
        let responseURL = URL(fileURLWithPath: request.responsePath)
        let cancellationURL = URL(fileURLWithPath: request.cancellationPath)
        let expectedResponseURL = requestDirectory.appendingPathComponent("response.json")
        let expectedCancellationURL = requestDirectory.appendingPathComponent("cancel")
        guard samePath(responseURL, expectedResponseURL),
              samePath(cancellationURL, expectedCancellationURL),
              isDescendant(responseURL.standardizedFileURL, of: rootURL),
              !isSymbolicLink(responseURL),
              !isSymbolicLink(cancellationURL)
        else { return nil }
        return ValidatedRequest(request: request, responseURL: expectedResponseURL)
    }

    private func privateRootURL() -> URL {
        fileManager.temporaryDirectory.appendingPathComponent("voiceink-inbox-companion", isDirectory: true)
            .standardizedFileURL
    }

    private func isSecureRequestPath(_ requestURL: URL, rootURL: URL) -> Bool {
        let canonicalRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard rootURL.standardizedFileURL.path == canonicalRootURL.path,
              !isSymbolicLink(rootURL), isOwnedByCurrentUser(rootURL), isDirectory(rootURL),
              isDescendant(requestURL.standardizedFileURL.resolvingSymlinksInPath(), of: canonicalRootURL)
        else { return false }

        let relativeComponents = requestURL.standardizedFileURL.pathComponents.dropFirst(canonicalRootURL.pathComponents.count)
        guard !relativeComponents.isEmpty else { return false }
        var currentURL = canonicalRootURL
        for component in relativeComponents {
            currentURL.appendPathComponent(component)
            guard !isSymbolicLink(currentURL), isOwnedByCurrentUser(currentURL) else { return false }
        }
        return isRegularFile(requestURL) && isDirectory(requestURL.deletingLastPathComponent())
    }

    private func isDescendant(_ url: URL, of rootURL: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path + "/")
    }

    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func isOwnedByCurrentUser(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber
        else { return false }
        return owner.uint32Value == getuid()
    }

    private func requestByteCount(at url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return .max }
        return size.int64Value
    }

    private func writeFailure(_ request: InboxCompanionRequest, code: InboxCompanionFailureCode, phase: String, retryable: Bool, to responseURL: URL) {
        write(failure(request, code: code, phase: phase, retryable: retryable), to: responseURL)
        log(requestId: request.requestId, phase: phase, code: code, startedAt: ContinuousClock.now)
    }

    private func failure(_ request: InboxCompanionRequest, code: InboxCompanionFailureCode, phase: String, retryable: Bool) -> InboxCompanionResponse {
        .failure(requestId: request.requestId, error: InboxCompanionFailure(code: code, phase: phase, message: "Inbox companion request failed.", retryable: retryable))
    }

    private func write(_ response: InboxCompanionResponse, to responseURL: URL) {
        let temporaryURL = responseURL.deletingLastPathComponent().appendingPathComponent(".response.\(UUID().uuidString).tmp")
        do {
            try InboxCompanionResponse.makeJSONEncoder().encode(response).write(to: temporaryURL, options: [])
            try rename(temporaryURL, to: responseURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            log(requestId: response.requestId, phase: "response", code: .internalFailure, startedAt: ContinuousClock.now)
        }
    }

    private func rename(_ sourceURL: URL, to destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in destinationURL.path.withCString { Darwin.rename(sourcePath, $0) } }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func log(requestId: UUID, phase: String, code: InboxCompanionFailureCode?, startedAt: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - startedAt
        let codeValue = code?.rawValue ?? "none"
        Self.logger.notice("Inbox companion request=\(requestId.uuidString, privacy: .private(mask: .hash)) phase=\(phase, privacy: .public) code=\(codeValue, privacy: .public) elapsed=\(elapsed.components.seconds, privacy: .public)s")
    }
}

private struct ValidatedRequest {
    let request: InboxCompanionRequest
    let responseURL: URL
}
