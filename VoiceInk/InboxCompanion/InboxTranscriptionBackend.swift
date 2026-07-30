import Foundation

@MainActor
protocol InboxTranscriptionBackend {
    func transcribe(wavURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String
    func cleanup() async
}

@MainActor
final class RegistryInboxTranscriptionBackend: InboxTranscriptionBackend {
    private let registry: TranscriptionServiceRegistry
    init(registry: TranscriptionServiceRegistry) { self.registry = registry }
    convenience init(engine: VoiceInkEngine) { self.init(registry: engine.serviceRegistry) }
    func transcribe(wavURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String { try await registry.transcribe(audioURL: wavURL, model: model, context: context) }
    func cleanup() async { await registry.cleanup() }
}
