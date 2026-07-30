import CryptoKit
import Foundation

struct InboxCompanionRuntimeSnapshot {
    let mode: ModeConfig
    let transcription: TranscriptionRuntimeConfiguration
    let formatting: TranscriptionFormattingConfiguration
    let prompt: String
    let promptSHA256: String
    let promptApplied: Bool
}

enum InboxCompanionPreflightError: Error, Equatable {
    case incompatibleContract, inputMissing, inputUnreadable
    case promptMissing, promptUnreadable, promptInvalidUTF8
    case inboxModeMissing, inboxModeDisabled, inboxModeDuplicate, aiEnhancementEnabled
    case modelNotSelected, modelNotFound, modelUnavailable, credentialMissing

    var failureCode: InboxCompanionFailureCode {
        switch self {
        case .incompatibleContract: .incompatibleContract
        case .inputMissing: .inputMissing
        case .inputUnreadable: .inputUnreadable
        case .promptMissing: .promptMissing
        case .promptUnreadable: .promptUnreadable
        case .promptInvalidUTF8: .promptInvalidUTF8
        case .inboxModeMissing: .inboxModeMissing
        case .inboxModeDisabled: .inboxModeDisabled
        case .inboxModeDuplicate: .inboxModeDuplicate
        case .aiEnhancementEnabled: .aiEnhancementEnabled
        case .modelNotSelected: .modelNotSelected
        case .modelNotFound: .modelNotFound
        case .modelUnavailable: .modelUnavailable
        case .credentialMissing: .credentialMissing
        }
    }
}

@MainActor
enum InboxCompanionPreflight {
    static func resolve(request: InboxCompanionRequest, modes: [ModeConfig], transcriptionModelManager: TranscriptionModelManager) throws -> InboxCompanionRuntimeSnapshot {
        guard request.contractVersion == InboxCompanionContract.version else { throw InboxCompanionPreflightError.incompatibleContract }
        let inputURL = URL(fileURLWithPath: request.inputPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else { throw InboxCompanionPreflightError.inputMissing }
        guard FileManager.default.isReadableFile(atPath: inputURL.path) else { throw InboxCompanionPreflightError.inputUnreadable }
        let promptURL = URL(fileURLWithPath: request.promptPath)
        guard FileManager.default.fileExists(atPath: promptURL.path) else { throw InboxCompanionPreflightError.promptMissing }
        let promptData: Data
        do { promptData = try Data(contentsOf: promptURL) } catch { throw InboxCompanionPreflightError.promptUnreadable }
        guard let prompt = String(data: promptData, encoding: .utf8) else { throw InboxCompanionPreflightError.promptInvalidUTF8 }
        let inboxModes = modes.filter { $0.name == "Inbox" }
        guard !inboxModes.isEmpty else { throw InboxCompanionPreflightError.inboxModeMissing }
        let enabledModes = inboxModes.filter(\.isEnabled)
        guard !enabledModes.isEmpty else { throw InboxCompanionPreflightError.inboxModeDisabled }
        guard enabledModes.count == 1, let mode = enabledModes.first else { throw InboxCompanionPreflightError.inboxModeDuplicate }
        guard !mode.isAIEnhancementEnabled else { throw InboxCompanionPreflightError.aiEnhancementEnabled }
        let resolution = ModeRuntimeResolver.transcriptionModelResolution(mode: mode, transcriptionModelManager: transcriptionModelManager)
        let transcription: TranscriptionRuntimeConfiguration
        switch resolution {
        case .noSelection: throw InboxCompanionPreflightError.modelNotSelected
        case .modelNotFound: throw InboxCompanionPreflightError.modelNotFound
        case .unavailable: throw InboxCompanionPreflightError.modelUnavailable
        case .available:
            guard let value = ModeRuntimeResolver.transcriptionConfiguration(from: resolution) else { throw InboxCompanionPreflightError.modelUnavailable }
            transcription = value
        case .noMode: throw InboxCompanionPreflightError.inboxModeMissing
        }
        guard hasCredential(for: transcription.model) else { throw InboxCompanionPreflightError.credentialMissing }
        return InboxCompanionRuntimeSnapshot(mode: mode, transcription: transcription, formatting: ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode), prompt: prompt, promptSHA256: SHA256.hash(data: promptData).map { String(format: "%02x", $0) }.joined(), promptApplied: transcription.model.provider == .whisper)
    }

    private static func hasCredential(for model: any TranscriptionModel) -> Bool {
        switch model.provider {
        case .whisper, .fluidAudio, .nativeApple: return true
        case .custom:
            guard let model = model as? CustomCloudModel else { return false }
            return !(APIKeyManager.shared.getCustomModelAPIKey(forModelId: model.id) ?? "").isEmpty
        default:
            guard let provider = CloudProviderRegistry.provider(for: model.provider) else { return false }
            return !(APIKeyManager.shared.getAPIKey(forProvider: provider.providerKey) ?? "").isEmpty
        }
    }
}
