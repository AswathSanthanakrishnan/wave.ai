import AVFoundation

/// PCM lives only in RAM. The audio callback owns the converter; the lock protects samples.
final class VoiceRecorder {
    let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var recording = false
    private var conversionFailed = false
    private var tapInstalled = false
    static let sampleRate = 16_000.0
    static let maxSeconds = 30.0

    var onSilenceAfterSpeech: (() -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    private var hasSpoken = false
    private var lastSpeechTime = 0.0

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: Self.sampleRate,
                                              channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw VoiceError.microphoneUnavailable
        }
        lock.lock()
        samples = []
        conversionFailed = false
        recording = true
        hasSpoken = false
        lastSpeechTime = 0.0
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * Self.sampleRate / inputFormat.sampleRate)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard let self else { return }
            lock.lock()
            defer { lock.unlock() }
            guard recording else { return }
            if error != nil { conversionFailed = true; return }
            guard let data = converted.floatChannelData?[0] else { return }
            let count = min(Int(converted.frameLength), Int(Self.sampleRate * Self.maxSeconds) - samples.count)
            if count > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
                var sum: Float = 0
                for i in 0..<count { sum += data[i] * data[i] }
                let rms = sqrt(sum / Float(count))
                let normalized = min(max((rms - 0.015) * 8.0, 0), 1.0)
                Task { @MainActor [weak self] in
                    self?.onAudioLevel?(normalized)
                }
                let now = ProcessInfo.processInfo.systemUptime
                if rms > 0.025 {
                    self.hasSpoken = true
                    self.lastSpeechTime = now
                } else if self.hasSpoken && (now - self.lastSpeechTime > 1.25) {
                    self.hasSpoken = false
                    Task { @MainActor [weak self] in
                        self?.onSilenceAfterSpeech?()
                    }
                }
            }
        }
        tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
        } catch {
            discard()
            throw error
        }
    }

    func finish() throws -> [Float] {
        lock.lock()
        recording = false
        let result = samples
        samples = []
        let failed = conversionFailed
        hasSpoken = false
        lock.unlock()
        onSilenceAfterSpeech = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.reset()
        if failed { throw VoiceError.microphoneUnavailable }
        return result
    }

    func discard() { _ = try? finish() }
}

enum VoiceError: LocalizedError {
    case microphoneUnavailable, modelMissing, noSpeech, backendUnavailable, backendResponse
    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: return "Microphone unavailable"
        case .modelMissing: return "Voice model missing — run Scripts/prepare-voice-model.sh and rebuild"
        case .noSpeech: return "No speech detected — try again"
        case .backendUnavailable: return "Backend not reachable"
        case .backendResponse: return "Backend returned an invalid reply"
        }
    }
}
