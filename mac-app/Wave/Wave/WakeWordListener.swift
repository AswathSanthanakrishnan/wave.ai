import Foundation
import AVFoundation
import Speech
import AppKit
import Combine

// MARK: - Wake Word Engine Protocol

protocol WakeWordEngine: AnyObject {
    var name: String { get }
    var isReady: Bool { get }
    func process(pcm: [Int16]) -> Bool
    func reset()
}

// MARK: - Porcupine Engine (Dynamic C-ABI Loader)

final class PorcupineEngine: WakeWordEngine {
    let name = "Picovoice Porcupine"
    private(set) var isReady = false

    private typealias PVInitFunc = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?,
        UnsafePointer<Float>?,
        UnsafeMutablePointer<OpaquePointer?>?
    ) -> Int32

    private typealias PVProcessFunc = @convention(c) (
        OpaquePointer?,
        UnsafePointer<Int16>?,
        UnsafeMutablePointer<Int32>?
    ) -> Int32

    private typealias PVDeleteFunc = @convention(c) (OpaquePointer?) -> Void
    private typealias PVFrameLengthFunc = @convention(c) () -> Int32
    private typealias PVSampleRateFunc = @convention(c) () -> Int32

    private var dylibHandle: UnsafeMutableRawPointer?
    private var porcupineObject: OpaquePointer?
    private var pvInit: PVInitFunc?
    private var pvProcess: PVProcessFunc?
    private var pvDelete: PVDeleteFunc?
    private var pvFrameLength: PVFrameLengthFunc?
    private var pvSampleRate: PVSampleRateFunc?

    let accessKey: String
    let sensitivity: Float

    init?(accessKey: String, sensitivity: Float = 0.45) {
        guard !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.accessKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sensitivity = max(0.0, min(1.0, sensitivity))

        guard let dylibPath = Self.findDylib() else {
            return nil
        }
        guard let handle = dlopen(dylibPath, RTLD_NOW) else {
            return nil
        }
        self.dylibHandle = handle

        guard let symInit = dlsym(handle, "pv_porcupine_init"),
              let symProcess = dlsym(handle, "pv_porcupine_process"),
              let symDelete = dlsym(handle, "pv_porcupine_delete") else {
            dlclose(handle)
            self.dylibHandle = nil
            return nil
        }

        self.pvInit = unsafeBitCast(symInit, to: PVInitFunc.self)
        self.pvProcess = unsafeBitCast(symProcess, to: PVProcessFunc.self)
        self.pvDelete = unsafeBitCast(symDelete, to: PVDeleteFunc.self)
        if let symFL = dlsym(handle, "pv_porcupine_frame_length") {
            self.pvFrameLength = unsafeBitCast(symFL, to: PVFrameLengthFunc.self)
        }
        if let symSR = dlsym(handle, "pv_sample_rate") {
            self.pvSampleRate = unsafeBitCast(symSR, to: PVSampleRateFunc.self)
        }

        guard initializeEngine() else {
            cleanup()
            return nil
        }
        self.isReady = true
    }

    deinit {
        cleanup()
    }

    private func initializeEngine() -> Bool {
        guard let pvInit, let modelPath = Self.findModelPath(), let keywordPath = Self.findKeywordPath() else {
            return false
        }

        var obj: OpaquePointer?
        let keyPaths = [keywordPath]
        let sensitivities: [Float] = [sensitivity]

        let cKeyPaths = keyPaths.map { strdup($0) }
        defer { for ptr in cKeyPaths { free(ptr) } }

        var cKeyPathsArray = cKeyPaths.map { UnsafePointer($0) }
        let status = cKeyPathsArray.withUnsafeMutableBufferPointer { bufferPtr -> Int32 in
            sensitivities.withUnsafeBufferPointer { sensPtr -> Int32 in
                pvInit(
                    accessKey,
                    modelPath,
                    1,
                    bufferPtr.baseAddress,
                    sensPtr.baseAddress,
                    &obj
                )
            }
        }

        if status == 0, let validObj = obj {
            self.porcupineObject = validObj
            return true
        }
        return false
    }

    func process(pcm: [Int16]) -> Bool {
        guard isReady, let pvProcess, let porcupineObject else { return false }
        var keywordIndex: Int32 = -1
        let status = pcm.withUnsafeBufferPointer { bufferPtr in
            pvProcess(porcupineObject, bufferPtr.baseAddress, &keywordIndex)
        }
        return status == 0 && keywordIndex >= 0
    }

    func reset() {}

    private func cleanup() {
        if let porcupineObject, let pvDelete {
            pvDelete(porcupineObject)
            self.porcupineObject = nil
        }
        if let dylibHandle {
            dlclose(dylibHandle)
            self.dylibHandle = nil
        }
        isReady = false
    }

    // MARK: - Asset Resolution

    static func findDylib() -> String? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.path(forResource: "libpv_porcupine", ofType: "dylib"),
            Bundle.main.bundlePath + "/Contents/Resources/libpv_porcupine.dylib",
            Bundle.main.bundlePath + "/Contents/Frameworks/libpv_porcupine.dylib",
            fileManager.currentDirectoryPath + "/Wave/VoiceModels/libpv_porcupine.dylib",
            fileManager.currentDirectoryPath + "/VoiceModels/libpv_porcupine.dylib",
            NSHomeDirectory() + "/Downloads/wave-mac/Wave/VoiceModels/libpv_porcupine.dylib",
            NSHomeDirectory() + "/Library/Application Support/Wave/libpv_porcupine.dylib",
            "/usr/local/lib/libpv_porcupine.dylib",
            "/opt/homebrew/lib/libpv_porcupine.dylib"
        ].compactMap { $0 }

        return candidates.first { fileManager.fileExists(atPath: $0) }
    }

    static func findModelPath() -> String? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.path(forResource: "porcupine_params", ofType: "pv"),
            Bundle.main.bundlePath + "/Contents/Resources/porcupine_params.pv",
            fileManager.currentDirectoryPath + "/Wave/VoiceModels/porcupine_params.pv",
            fileManager.currentDirectoryPath + "/VoiceModels/porcupine_params.pv",
            NSHomeDirectory() + "/Downloads/wave-mac/Wave/VoiceModels/porcupine_params.pv",
            NSHomeDirectory() + "/Library/Application Support/Wave/porcupine_params.pv"
        ].compactMap { $0 }

        return candidates.first { fileManager.fileExists(atPath: $0) }
    }

    static func findKeywordPath() -> String? {
        let fileManager = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "porcupine_keyword_path"),
           fileManager.fileExists(atPath: custom) {
            return custom
        }

        let searchDirs = [
            Bundle.main.resourcePath,
            fileManager.currentDirectoryPath + "/Wave/VoiceModels",
            fileManager.currentDirectoryPath + "/VoiceModels",
            NSHomeDirectory() + "/Downloads/wave-mac/Wave/VoiceModels",
            NSHomeDirectory() + "/Library/Application Support/Wave"
        ].compactMap { $0 }

        for dir in searchDirs {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            // Prefer custom Hey Wave keyword file
            if let heyWave = contents.first(where: {
                let name = $0.lowercased()
                return name.contains("wave") && name.hasSuffix(".ppn")
            }) {
                return (dir as NSString).appendingPathComponent(heyWave)
            }
            // Fall back to built-in keyword (e.g. porcupine_mac.ppn)
            if let anyPpn = contents.first(where: { $0.hasSuffix(".ppn") }) {
                return (dir as NSString).appendingPathComponent(anyPpn)
            }
        }
        return nil
    }
}

// MARK: - On-Device Apple Speech Engine (Zero-Key Offline Fallback)

final class AppleOnDeviceWakeEngine: WakeWordEngine {
    let name = "Apple Speech (On-Device)"
    private(set) var isReady = false

    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFormat: AVAudioFormat?
    private var wakeTriggered = false
    private let lock = NSLock()

    var onWake: (() -> Void)?

    init() {
        let loc = Locale(identifier: "en-US")
        let rec = SFSpeechRecognizer(locale: loc)
        self.recognizer = rec
        self.isReady = rec?.isAvailable ?? false
    }

    func startStream() {
        lock.lock()
        defer { lock.unlock() }

        recognitionTask?.cancel()
        recognitionTask = nil
        wakeTriggered = false

        guard let recognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        self.audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)
        self.recognitionRequest = request

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString.lowercased()
            // Look for "hey wave" or "wave"
            if text.contains("hey wave") || text.contains("wave") || text.contains("hey, wave") {
                self.lock.lock()
                let already = self.wakeTriggered
                self.wakeTriggered = true
                self.lock.unlock()
                if !already {
                    self.onWake?()
                }
            }
        }
    }

    func stopStream() {
        lock.lock()
        defer { lock.unlock() }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        wakeTriggered = false
    }

    func process(pcm: [Int16]) -> Bool {
        guard !pcm.isEmpty else { return false }
        lock.lock()
        guard let request = recognitionRequest, let format = audioFormat else {
            lock.unlock()
            return false
        }
        let frameCount = AVAudioFrameCount(pcm.count)
        guard frameCount > 0, let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            lock.unlock()
            return false
        }
        pcmBuffer.frameLength = frameCount
        if let channelData = pcmBuffer.int16ChannelData?[0] {
            pcm.withUnsafeBufferPointer { src in
                channelData.update(from: src.baseAddress!, count: pcm.count)
            }
            if pcmBuffer.frameLength > 0 {
                request.append(pcmBuffer)
            }
        }
        let triggered = wakeTriggered
        if triggered {
            wakeTriggered = false
        }
        lock.unlock()
        return triggered
    }

    func reset() {
        lock.lock()
        wakeTriggered = false
        lock.unlock()
        startStream()
    }
}

// MARK: - Wake Word Listener

@MainActor
final class WakeWordListener: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var activeEngineName = "None"
    @Published private(set) var statusMessage = "Wake Word: Off"

    var onWakeDetected: (@MainActor () -> Void)?
    var statusChanged: (@MainActor (String) -> Void)?

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var currentEngine: (any WakeWordEngine)?
    private var sampleBuffer: [Int16] = []
    private let lock = NSLock()
    private var isPaused = false

    static let sampleRate = 16_000.0
    static let porcupineFrameLength = 512

    init() {
        rebuildEngine()
    }

    func rebuildEngine() {
        let accessKey = UserDefaults.standard.string(forKey: "porcupine_access_key") ?? ""
        let sensitivity = Float(UserDefaults.standard.double(forKey: "wake_word_sensitivity"))
        let effectiveSens = sensitivity > 0 ? sensitivity : 0.45

        if let porcupine = PorcupineEngine(accessKey: accessKey, sensitivity: effectiveSens), porcupine.isReady {
            self.currentEngine = porcupine
            self.activeEngineName = porcupine.name
            self.statusMessage = "Listening for 'Hey Wave' (Porcupine)"
        } else {
            let appleEngine = AppleOnDeviceWakeEngine()
            appleEngine.onWake = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleWake()
                }
            }
            self.currentEngine = appleEngine
            self.activeEngineName = appleEngine.name
            self.statusMessage = "Listening for 'Hey Wave' (Local)"
        }
    }

    func start() {
        guard !isListening else { return }
        isPaused = false
        rebuildEngine()

        if let apple = currentEngine as? AppleOnDeviceWakeEngine {
            apple.startStream()
        }

        do {
            try startAudioCapture()
            isListening = true
            statusMessage = "Listening for 'Hey Wave'"
            statusChanged?(statusMessage)
        } catch {
            isListening = false
            statusMessage = "Wake word mic unavailable: \(error.localizedDescription)"
            statusChanged?(statusMessage)
        }
    }

    func stop() {
        isPaused = false
        stopAudioCapture()
        if let apple = currentEngine as? AppleOnDeviceWakeEngine {
            apple.stopStream()
        }
        isListening = false
        statusMessage = "Wake Word: Off"
        statusChanged?(statusMessage)
    }

    func pause() {
        guard isListening, !isPaused else { return }
        isPaused = true
        if let apple = currentEngine as? AppleOnDeviceWakeEngine {
            apple.stopStream()
        }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if let apple = currentEngine as? AppleOnDeviceWakeEngine {
            apple.startStream()
        }
    }

    private func handleWake() {
        guard isListening, !isPaused else { return }
        pause()
        onWakeDetected?()
    }

    // MARK: - Audio Capture

    private func startAudioCapture() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let intermediateFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                     sampleRate: Self.sampleRate,
                                                     channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: intermediateFormat) else {
            throw VoiceError.microphoneUnavailable
        }

        lock.lock()
        sampleBuffer.removeAll(keepingCapacity: true)
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self.isPaused, buffer.frameLength > 0 else { return }

            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * Self.sampleRate / inputFormat.sampleRate)) + 32
            guard capacity > 0, let converted = AVAudioPCMBuffer(pcmFormat: intermediateFormat, frameCapacity: capacity) else { return }

            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }

            guard error == nil, converted.frameLength > 0, let floatData = converted.floatChannelData?[0] else { return }
            let count = Int(converted.frameLength)
            guard count > 0 else { return }

            // Convert Float32 (-1.0...1.0) to Int16 (-32768...32767)
            var int16Samples = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                let scaled = max(-1.0, min(1.0, floatData[i])) * 32767.0
                int16Samples[i] = Int16(scaled)
            }

            self.lock.lock()
            self.sampleBuffer.append(contentsOf: int16Samples)

            var framesToProcess: [[Int16]] = []
            while self.sampleBuffer.count >= Self.porcupineFrameLength {
                let frame = Array(self.sampleBuffer.prefix(Self.porcupineFrameLength))
                self.sampleBuffer.removeFirst(Self.porcupineFrameLength)
                framesToProcess.append(frame)
            }
            self.lock.unlock()

            guard let activeEngine = self.currentEngine else { return }

            for frame in framesToProcess {
                if activeEngine.process(pcm: frame) {
                    Task { @MainActor [weak self] in
                        self?.handleWake()
                    }
                    break
                }
            }
        }

        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func stopAudioCapture() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.reset()
        lock.lock()
        sampleBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
