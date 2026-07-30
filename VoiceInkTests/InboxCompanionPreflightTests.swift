import Foundation
import Testing

@testable import VoiceInk

@Suite(.serialized)
@MainActor
struct InboxCompanionPreflightTests {
    private let prompt = "inbox prompt"

    @Test func missingInboxModeIsDistinct() throws {
        let fixture = try makeFixture(modes: [])

        #expect(throws: InboxCompanionPreflightError.inboxModeMissing) {
            try InboxCompanionPreflight.resolve(
                request: fixture.request,
                modes: fixture.modes,
                transcriptionModelManager: fixture.manager
            )
        }
    }

    @Test func disabledInboxModeIsDistinct() throws {
        var mode = inboxMode()
        mode.isEnabled = false
        let fixture = try makeFixture(modes: [mode])

        #expect(throws: InboxCompanionPreflightError.inboxModeDisabled) {
            try InboxCompanionPreflight.resolve(request: fixture.request, modes: fixture.modes, transcriptionModelManager: fixture.manager)
        }
    }

    @Test func duplicateEnabledInboxModesAreDistinct() throws {
        let fixture = try makeFixture(modes: [inboxMode(), inboxMode(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)])

        #expect(throws: InboxCompanionPreflightError.inboxModeDuplicate) {
            try InboxCompanionPreflight.resolve(request: fixture.request, modes: fixture.modes, transcriptionModelManager: fixture.manager)
        }
    }

    @Test func aiEnhancedInboxModeIsRejected() throws {
        var mode = inboxMode()
        mode.isAIEnhancementEnabled = true
        let fixture = try makeFixture(modes: [mode])

        #expect(throws: InboxCompanionPreflightError.aiEnhancementEnabled) {
            try InboxCompanionPreflight.resolve(request: fixture.request, modes: fixture.modes, transcriptionModelManager: fixture.manager)
        }
    }

    @Test func missingModelSelectionIsDistinct() throws {
        var mode = inboxMode()
        mode.selectedTranscriptionModelName = nil
        let fixture = try makeFixture(modes: [mode])

        #expect(throws: InboxCompanionPreflightError.modelNotSelected) {
            try InboxCompanionPreflight.resolve(request: fixture.request, modes: fixture.modes, transcriptionModelManager: fixture.manager)
        }
    }

    @Test func unavailableModelIsRejectedBeforeAudioPreparation() throws {
        let fixture = try makeFixture(modes: [inboxMode()], isModelUsable: false)

        #expect(throws: InboxCompanionPreflightError.modelUnavailable) {
            try InboxCompanionPreflight.resolve(request: fixture.request, modes: fixture.modes, transcriptionModelManager: fixture.manager)
        }
    }

    @Test func missingCloudCredentialIsRejectedBeforeAudioPreparation() throws {
        let customModel = CustomCloudModel(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            name: "inbox-custom",
            displayName: "Inbox custom",
            description: "Test custom cloud model",
            apiEndpoint: "https://example.invalid/v1/audio/transcriptions",
            modelName: "inbox-custom"
        )
        let fixture = try makeFixture(modes: [inboxMode(modelName: customModel.name)], model: customModel)

        #expect(throws: InboxCompanionPreflightError.credentialMissing) {
            try InboxCompanionPreflight.resolve(request: fixture.request, modes: fixture.modes, transcriptionModelManager: fixture.manager)
        }
    }

    @Test func missingPromptIsDistinct() throws {
        let fixture = try makeFixture(modes: [inboxMode()])
        try FileManager.default.removeItem(atPath: fixture.request.promptPath)

        #expect(throws: InboxCompanionPreflightError.promptMissing) {
            try InboxCompanionPreflight.resolve(request: fixture.request, modes: fixture.modes, transcriptionModelManager: fixture.manager)
        }
    }

    @Test func invalidUTF8PromptIsDistinct() throws {
        let fixture = try makeFixture(modes: [inboxMode()])
        try Data([0xFF]).write(to: URL(fileURLWithPath: fixture.request.promptPath))

        #expect(throws: InboxCompanionPreflightError.promptInvalidUTF8) {
            try InboxCompanionPreflight.resolve(request: fixture.request, modes: fixture.modes, transcriptionModelManager: fixture.manager)
        }
    }

    @Test func unknownContractVersionIsRejected() throws {
        let fixture = try makeFixture(modes: [inboxMode()])
        let request = InboxCompanionRequest(
            contractVersion: 99,
            requestId: fixture.request.requestId,
            inputPath: fixture.request.inputPath,
            promptPath: fixture.request.promptPath,
            responsePath: fixture.request.responsePath,
            cancellationPath: fixture.request.cancellationPath,
            timeoutSeconds: fixture.request.timeoutSeconds
        )

        #expect(throws: InboxCompanionPreflightError.incompatibleContract) {
            try InboxCompanionPreflight.resolve(request: request, modes: fixture.modes, transcriptionModelManager: fixture.manager)
        }
    }

    @Test func enabledExactCaseInboxModeResolvesRuntimeSnapshot() throws {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let fixture = try makeFixture(modes: [inboxMode(id: id)])

        let snapshot = try InboxCompanionPreflight.resolve(
            request: fixture.request,
            modes: fixture.modes,
            transcriptionModelManager: fixture.manager
        )

        #expect(snapshot.mode.id == id)
        #expect(snapshot.transcription.model.name == "inbox-whisper")
        #expect(snapshot.transcription.language == "ru")
        #expect(snapshot.formatting.isTextFormattingEnabled)
        #expect(snapshot.promptSHA256 == "e05be0d2af992ec33298fc4a883ff1477d6cec6e4fd247ae030e29346b7b8e1e")
        #expect(snapshot.promptApplied)
    }

    private func inboxMode(
        id: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        modelName: String = "inbox-whisper"
    ) -> ModeConfig {
        ModeConfig(
            id: id,
            name: "Inbox",
            isAIEnhancementEnabled: false,
            selectedTranscriptionModelName: modelName,
            selectedLanguage: "ru",
            isTextFormattingEnabled: true,
            isEnabled: true
        )
    }

    private func makeFixture(
        modes: [ModeConfig],
        model: (any TranscriptionModel)? = nil,
        isModelUsable: Bool = true
    ) throws -> (
        request: InboxCompanionRequest,
        modes: [ModeConfig],
        manager: TranscriptionModelManager,
        whisperModelManager: WhisperModelManager,
        fluidAudioModelManager: FluidAudioModelManager
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inputURL = directory.appendingPathComponent("input.m4a")
        let promptURL = directory.appendingPathComponent("prompt.txt")
        try Data("input bytes".utf8).write(to: inputURL)
        try Data(prompt.utf8).write(to: promptURL)

        let whisper = WhisperModelManager(modelsDirectory: directory)
        let fluidAudio = FluidAudioModelManager()
        let manager = TranscriptionModelManager(whisperModelManager: whisper, fluidAudioModelManager: fluidAudio)
        let selectedModel = model ?? WhisperModel(
            name: "inbox-whisper",
            displayName: "Inbox Whisper",
            size: "test",
            supportedLanguages: ["en": "English", "ru": "Russian"],
            description: "Test Whisper model",
            speed: 1,
            accuracy: 1,
            ramUsage: 1
        )
        manager.allAvailableModels = [selectedModel]
        if isModelUsable, selectedModel.provider == .whisper {
            whisper.availableModels = [WhisperModelFile(name: selectedModel.name, url: directory.appendingPathComponent("\(selectedModel.name).bin"))]
        }

        return (
            InboxCompanionRequest(
                contractVersion: InboxCompanionContract.version,
                requestId: UUID(),
                inputPath: inputURL.path,
                promptPath: promptURL.path,
                responsePath: directory.appendingPathComponent("response.json").path,
                cancellationPath: directory.appendingPathComponent("cancel").path,
                timeoutSeconds: 30
            ),
            modes,
            manager,
            whisper,
            fluidAudio
        )
    }
}
