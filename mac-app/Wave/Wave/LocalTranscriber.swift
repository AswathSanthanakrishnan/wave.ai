import Foundation
import WhisperKit
import ArgmaxCore

/// Both model and tokenizer are bundled; recording and transcription never use cloud services.
actor LocalTranscriber {
    private var whisper: WhisperKit?
    private let modelFolder: URL?

    init(modelFolder: URL? = Bundle.main.resourceURL?.appendingPathComponent("VoiceModels")) {
        self.modelFolder = modelFolder
    }

    func prepare() async throws {
        guard whisper == nil else { return }
        guard let folder = modelFolder,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("MelSpectrogram.mlmodelc").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer_config.json").path) else {
            throw VoiceError.modelMissing
        }
        // Validate the local tokenizer before WhisperKit's convenience loader, which otherwise
        // attempts a remote fallback for absent/corrupt tokenizer files. Bundle files are immutable.
        _ = try await AutoTokenizerWrapper.from(modelFolder: folder)
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder,
                                      verbose: false, logLevel: .none, prewarm: false,
                                      load: true, download: false)
        whisper = try await WhisperKit(config)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let whisper else { throw VoiceError.modelMissing }
        guard samples.count >= 4_000,
              samples.contains(where: { abs($0) > 0.008 }) else { throw VoiceError.noSpeech }
        // WhisperKit defaults to trimming a full second; short voice commands must still decode.
        let options = DecodingOptions(language: "en", skipSpecialTokens: true,
                                      withoutTimestamps: true, windowClipTime: 0)
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceError.noSpeech }
        return text
    }
}
