import Foundation
import SwiftData

protocol InboxAudioPreparing { func prepareReadOnlyInput(_ input: URL, wavOutput: URL) async throws -> TimeInterval }

final class InboxAudioPreparer: InboxAudioPreparing {
    private let processor = AudioProcessor()
    func prepareReadOnlyInput(_ input: URL, wavOutput: URL) async throws -> TimeInterval {
        let samples = try await processor.processAudioToSamples(input)
        try processor.saveSamplesAsWav(samples: samples, to: wavOutput)
        return await AudioFileMetadata.duration(for: input)
    }
}

@MainActor
protocol InboxTranscriptionRunning {
    func run(request: InboxCompanionRequest, snapshot: InboxCompanionRuntimeSnapshot, cancellation: TranscriptionCancellationToken) async -> InboxCompanionResponse
}

@MainActor
final class InboxTranscriptionRunner: InboxTranscriptionRunning {
    private let audioPreparer: any InboxAudioPreparing
    private let backend: any InboxTranscriptionBackend
    private let modelContext: ModelContext
    init(audioPreparer: any InboxAudioPreparing = InboxAudioPreparer(), backend: any InboxTranscriptionBackend, modelContext: ModelContext) { self.audioPreparer = audioPreparer; self.backend = backend; self.modelContext = modelContext }

    func run(request: InboxCompanionRequest, snapshot: InboxCompanionRuntimeSnapshot, cancellation: TranscriptionCancellationToken) async -> InboxCompanionResponse {
        let requestDirectory = URL(fileURLWithPath: request.responsePath).deletingLastPathComponent()
        let wavURL = requestDirectory.appendingPathComponent("request-audio.wav")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            // WAV cleanup is synchronous; backend cleanup is awaited below before returning.
        }
        let response: InboxCompanionResponse
        do {
            try cancellation.throwIfCancelled()
            guard FileManager.default.fileExists(atPath: requestDirectory.path), URL(fileURLWithPath: request.cancellationPath).deletingLastPathComponent() == requestDirectory else { throw InboxCompanionPreflightError.inputUnreadable }
            let duration = try await audioPreparer.prepareReadOnlyInput(URL(fileURLWithPath: request.inputPath), wavOutput: wavURL)
            try cancellation.throwIfCancelled()
            let context = TranscriptionRequestContext(language: snapshot.transcription.language, prompt: snapshot.promptApplied ? snapshot.prompt : nil)
            var text = try await backend.transcribe(wavURL: wavURL, model: snapshot.transcription.model, context: context)
            try cancellation.throwIfCancelled()
            text = TranscriptionOutputFilter.filter(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if snapshot.formatting.isTextFormattingEnabled { text = ParagraphFormatter.format(text) }
            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                response = failure(request, .emptyTranscript, "transcription", false)
            } else {
                let result = InboxCompanionSuccess(transcript: text, mode: InboxCompanionModeIdentity(id: snapshot.mode.id, name: snapshot.mode.name), model: InboxCompanionModelIdentity(name: snapshot.transcription.model.name, displayName: snapshot.transcription.model.displayName, provider: snapshot.transcription.model.provider.rawValue), language: snapshot.transcription.language, mediaDurationSeconds: duration, execution: isLocal(snapshot.transcription.model.provider) ? .local : .cloud, prompt: InboxCompanionPromptMetadata(applied: snapshot.promptApplied, sha256: snapshot.promptSHA256), aiEnhancementApplied: false)
                response = .success(requestId: request.requestId, result: result)
            }
        } catch is CancellationError { response = failure(request, .cancelled, "transcription", false) }
        catch let error as CloudTranscriptionError { response = mapCloud(request, error) }
        catch let error as InboxCompanionPreflightError { response = failure(request, error.failureCode, "preflight", false) }
        catch { response = failure(request, .providerFailure, "transcription", true) }
        await backend.cleanup()
        return response
    }
    private func isLocal(_ provider: ModelProvider) -> Bool { provider == .whisper || provider == .fluidAudio || provider == .nativeApple }
    private func failure(_ request: InboxCompanionRequest, _ code: InboxCompanionFailureCode, _ phase: String, _ retryable: Bool) -> InboxCompanionResponse { .failure(requestId: request.requestId, error: InboxCompanionFailure(code: code, phase: phase, message: "Inbox transcription failed.", retryable: retryable)) }
    private func mapCloud(_ request: InboxCompanionRequest, _ error: CloudTranscriptionError) -> InboxCompanionResponse {
        switch error {
        case .invalidAPIKey, .missingAPIKey: return failure(request, .authenticationFailed, "transcription", false)
        case .apiRequestFailed(let status, _) where status == 429: return failure(request, .rateLimited, "transcription", true)
        case .apiRequestFailed(let status, _) where status == 401 || status == 403: return failure(request, .authenticationFailed, "transcription", false)
        case .networkError: return failure(request, .networkFailure, "transcription", true)
        default: return failure(request, .providerFailure, "transcription", true)
        }
    }
}
