import Foundation

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

    static func success(requestId: UUID, result: InboxCompanionSuccess) -> InboxCompanionResponse {
        InboxCompanionResponse(
            contractVersion: InboxCompanionContract.version,
            requestId: requestId,
            status: .success,
            result: result,
            error: nil
        )
    }

    static func failure(requestId: UUID, error: InboxCompanionFailure) -> InboxCompanionResponse {
        InboxCompanionResponse(
            contractVersion: InboxCompanionContract.version,
            requestId: requestId,
            status: .failure,
            result: nil,
            error: error
        )
    }

    static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
