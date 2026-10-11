import Foundation
import WhisperKit

/// Runs against generated test speech, never microphone audio.
@main
struct VoiceTranscriptionSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: voice-smoke MODEL_FOLDER TEST_AUDIO_PATH")
        }
        let transcriber = LocalTranscriber(modelFolder: URL(fileURLWithPath: CommandLine.arguments[1]))
        try await transcriber.prepare()
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: CommandLine.arguments[2])
        let text = try await transcriber.transcribe(audio)
        print("TRANSCRIPT: \(text)")
        precondition(text.lowercased().contains("hello"), "Expected hello in transcription")
        let reply = try await VoiceBackend().ask(text)
        print("REPLY: \(reply)")
    }
}
