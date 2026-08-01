import Foundation
import os

#if canImport(whisper)
    import whisper
#else
    #error("Unable to import whisper module. Please check your project configuration.")
#endif

// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer?
    private var language: String?
    private var languageCString: [CChar]?
    private var prompt: String?
    private var promptCString: [CChar]?
    private var vadModelPath: String?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperContext")

    private init() {}

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        if let context = context {
            whisper_free(context)
        }
    }

    func fullTranscribe(samples: [Float], cancellation: TranscriptionCancellationToken? = nil) throws -> Bool {
        guard let context = context else { return false }

        let maxThreads = max(1, min(8, cpuCount() - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let selectedLanguage = language ?? "auto"
        if selectedLanguage != "auto" {
            languageCString = Array(selectedLanguage.utf8CString)
            params.language = languageCString?.withUnsafeBufferPointer { ptr in
                ptr.baseAddress
            }
        } else {
            languageCString = nil
            params.language = nil
        }

        if prompt != nil {
            promptCString = Array(prompt!.utf8CString)
            params.initial_prompt = promptCString?.withUnsafeBufferPointer { ptr in
                ptr.baseAddress
            }
        } else {
            promptCString = nil
            params.initial_prompt = nil
        }

        params.print_realtime = true
        params.print_progress = false
        params.print_timestamps = true
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.temperature = 0.2

        // ggml polls this before each computation and aborts as soon as it returns true.
        // The callback must not capture, so the token travels through the user-data pointer.
        if let cancellation {
            params.abort_callback = { userData in
                guard let userData else { return false }
                return Unmanaged<TranscriptionCancellationToken>.fromOpaque(userData)
                    .takeUnretainedValue()
                    .isCancelled
            }
            params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
        }

        whisper_reset_timings(context)

        // Configure VAD if enabled by user and model is available
        let isVADEnabled = UserDefaults.standard.bool(forKey: "IsVADEnabled")
        if isVADEnabled, let vadModelPath = self.vadModelPath {
            params.vad = true
            params.vad_model_path = (vadModelPath as NSString).utf8String

            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.50
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        } else {
            params.vad = false
        }

        var success = true
        withExtendedLifetime(cancellation) {
            samples.withUnsafeBufferPointer { samplesBuffer in
                if whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count)) != 0 {
                    logger.error("❌ Failed to run whisper_full. VAD enabled: \(params.vad, privacy: .public)")
                    success = false
                }
            }
        }

        languageCString = nil
        promptCString = nil

        // An aborted run is a cancellation, not a core engine fault.
        if !success, cancellation?.isCancelled == true {
            throw CancellationError()
        }

        return success
    }

    func getTranscription() -> String {
        guard let context = context else { return "" }
        var transcription = ""
        for i in 0..<whisper_full_n_segments(context) {
            transcription += String(cString: whisper_full_get_segment_text(context, i))
        }
        return transcription
    }

    static func createContext(path: String) async throws -> WhisperContext {
        let whisperContext = WhisperContext()
        try await whisperContext.initializeModel(path: path)

        // Load VAD model from bundle resources
        let vadModelPath = await VADModelManager.shared.getModelPath()
        await whisperContext.setVADModelPath(vadModelPath)

        return whisperContext
    }

    private func initializeModel(path: String) throws {
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
            params.use_gpu = false
            logger.info("Running on the simulator, using CPU")
        #else
            params.flash_attn = true  // Enable flash attention for Metal
            logger.info("Flash attention enabled for Metal")
        #endif

        let context = whisper_init_from_file_with_params(path, params)
        if let context {
            self.context = context
        } else {
            logger.error("❌ Couldn't load model at \(path, privacy: .public)")
            throw VoiceInkEngineError.modelLoadFailed
        }
    }

    private func setVADModelPath(_ path: String?) {
        self.vadModelPath = path
        if path != nil {
            logger.info("VAD model loaded from bundle resources")
        }
    }

    func releaseResources() {
        if let context = context {
            whisper_free(context)
            self.context = nil
        }
        languageCString = nil
    }

    func setPrompt(_ prompt: String?) {
        self.prompt = prompt
    }

    func setLanguage(_ language: String?) {
        self.language = language
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
