# Wave Phase 1b — complete voice code

All paths are relative to `~/Downloads/wave-mac`. Add the Swift files to the existing Wave app target. The supplied Xcode project already includes them, WhisperKit, and the bundled model.

## Wave/Wave/WaveApp.swift

```swift
import SwiftUI

@main
struct WaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            WaveMenu(model: delegate.model, voice: delegate.voice)
        } label: {
            VoiceMenuLabel(voice: delegate.voice)
        }
    }
}

private struct WaveMenu: View {
    @ObservedObject var model: WaveModel
    @ObservedObject var voice: VoiceModel

    var body: some View {
        Toggle(model.modeTitle, isOn: Binding(
            get: { model.isActive },
            set: { model.setEnabled($0) }
        ))
        Text(model.status)
        if !model.accessibilityGranted {
            Button("Open Accessibility Settings…") { model.openAccessibility() }
        }
        Divider()
        Text(voice.status)
        Text("Push to talk: ⌃⌥Space")
        if !voice.hotKeyAvailable {
            Text("Voice hotkey needs Accessibility permission")
        }
        Button("Test voice") { voice.testVoice() }
            .disabled(voice.busy || !voice.modelReady)
        if voice.busy && voice.modelReady {
            Button("Cancel voice") { voice.cancel() }
        }
        if !voice.modelReady && !voice.busy {
            Button("Retry voice setup") { voice.prepare() }
        }
        if voice.microphoneDenied {
            Button("Open Microphone Settings…") { voice.openMicrophoneSettings() }
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

private struct VoiceMenuLabel: View {
    @ObservedObject var voice: VoiceModel
    var body: some View {
        Label(voice.listening ? "Listening..." : "Wave",
              systemImage: voice.listening ? "mic.fill" : "hand.wave.fill")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = WaveModel()
    let voice = VoiceModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        voice.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        voice.stop()
    }
}
```

## Wave/Wave/VoiceHotKey.swift

```swift
import AppKit
import ApplicationServices

/// An active event tap consumes Control–Option–Space, even outside Wave.
@MainActor
final class VoiceHotKey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    private var swallowedSpace = false
    private var permissionTimer: Timer?
    var onAvailability: ((Bool) -> Void)?

    func start() {
        installIfPermitted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.installIfPermitted() }
        }
    }

    private func installIfPermitted() {
        guard AXIsProcessTrusted() else {
            if held { held = false; enqueue(onCancel) }
            onAvailability?(false)
            return
        }
        guard tap == nil else { onAvailability?(true); return }
        let mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue) |
                   (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // This tap's source is attached only to the main run loop.
            return MainActor.assumeIsolated {
                let owner = Unmanaged<VoiceHotKey>.fromOpaque(context).takeUnretainedValue()
                return owner.handle(type, event: event)
            }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                         callback: callback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            onAvailability?(false)
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onAvailability?(true)
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if held { held = false; enqueue(onCancel) }
            swallowedSpace = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let chord = event.flags.contains([.maskControl, .maskAlternate]) &&
                    !event.flags.contains(.maskCommand) && !event.flags.contains(.maskShift)
        let space = event.getIntegerValueField(.keyboardEventKeycode) == 49
        if type == .keyDown && space && (chord || swallowedSpace) {
            if !swallowedSpace && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                swallowedSpace = true
                held = true
                enqueue(onPress)
            }
            return nil
        }
        if type == .keyUp && space && swallowedSpace {
            swallowedSpace = false
            if held { held = false; enqueue(onRelease) }
            return nil
        }
        if type == .flagsChanged && held && !chord {
            held = false
            enqueue(onRelease)
        }
        return Unmanaged.passUnretained(event)
    }

    private func enqueue(_ action: (() -> Void)?) {
        // Keep the event-tap callback short; audio shutdown happens after it returns.
        DispatchQueue.main.async { action?() }
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if held { enqueue(onCancel) }
        held = false
        swallowedSpace = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }
}
```

## Wave/Wave/VoiceRecorder.swift

```swift
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
            if count > 0 { samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count)) }
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
        lock.unlock()
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
```

## Wave/Wave/LocalTranscriber.swift

```swift
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
```

## Wave/Wave/VoiceBackend.swift

```swift
import Foundation

struct VoiceBackend {
    var configuration: URLSessionConfiguration = .ephemeral
    private struct Request: Encodable { let text: String }
    private struct Reply: Decodable { let reply: String }

    func ask(_ text: String) async throws -> String {
        let config = configuration
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 95
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4000/ask")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(text: text))
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw VoiceError.backendUnavailable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceError.backendResponse
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              !reply.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceError.backendResponse
        }
        return reply.reply
    }
}

/// Never follow a backend redirect to another host or a cloud service.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
```

## Wave/Wave/VoiceModel.swift

```swift
import AppKit
import AVFoundation
import Combine

@MainActor
final class VoiceModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var status = "Preparing voice model…"
    @Published private(set) var listening = false
    @Published private(set) var busy = true
    @Published private(set) var hotKeyAvailable = false
    @Published private(set) var microphoneDenied = false
    @Published private(set) var modelReady = false
    private let hotKey = VoiceHotKey()
    private let recorder = VoiceRecorder()
    private let transcriber = LocalTranscriber()
    private let synthesizer = AVSpeechSynthesizer()
    private var processing = false
    private var currentUtterance: AVSpeechUtterance?
    private var round: UUID?
    private var source: InputSource?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private enum InputSource { case hotKey, menuTest }

    func start() {
        synthesizer.delegate = self
        hotKey.onPress = { [weak self] in self?.begin(.hotKey) }
        hotKey.onRelease = { [weak self] in
            guard self?.source == .hotKey else { return }
            self?.finish()
        }
        hotKey.onCancel = { [weak self] in self?.cancel() }
        hotKey.onAvailability = { [weak self] in self?.hotKeyAvailable = $0 }
        hotKey.start()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.cancel() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: recorder.engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.listening else { return }
                self.cancel()
                self.status = "Microphone changed — try again"
            }
        })
        prepare()
    }

    func prepare() {
        guard !modelReady else { return }
        busy = true
        status = "Preparing voice model…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await transcriber.prepare()
                try Task.checkCancellation()
                modelReady = true
                status = "Voice ready — hold ⌃⌥Space"
            } catch is CancellationError { return }
            catch { status = "Voice unavailable: \(error.localizedDescription)" }
            busy = false
        }
    }

    func testVoice() { begin(.menuTest) }

    private func begin(_ inputSource: InputSource) {
        guard modelReady, !busy, round == nil else { return }
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        let id = UUID()
        round = id
        source = inputSource
        busy = true
        status = "Waiting for microphone permission…"
        work = Task { [weak self] in
            guard let self else { return }
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
            default: allowed = false
            }
            // Releasing during the permission prompt must not start a late recording.
            guard round == id, !Task.isCancelled else { return }
            microphoneDenied = !allowed
            guard allowed else {
                round = nil
                source = nil
                busy = false
                status = "Microphone permission required"
                return
            }
            do {
                try recorder.start()
                listening = true
                status = "Listening..."
                let seconds = inputSource == .menuTest ? 5.0 : VoiceRecorder.maxSeconds
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    guard let self, self.round == id else { return }
                    self.finish()
                }
            } catch {
                recorder.discard()
                round = nil
                source = nil
                busy = false
                status = "Microphone unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func finish() {
        guard let id = round else { return }
        deadline?.cancel()
        deadline = nil
        guard listening else { cancel(); return }
        listening = false
        source = nil
        let samples: [Float]
        do { samples = try recorder.finish() }
        catch { cancel(); status = error.localizedDescription; return }
        status = "Transcribing…"
        processing = true
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                processing = false
                if round == nil {
                    busy = false
                    if Task.isCancelled { status = "Voice ready — hold ⌃⌥Space" }
                }
            }
            do {
                let text = try await transcriber.transcribe(samples)
                try Task.checkCancellation()
                guard round == id else { return }
                status = "Asking Wave…"
                let reply = try await VoiceBackend().ask(text)
                try Task.checkCancellation()
                guard round == id else { return }
                round = nil
                busy = false
                status = "Speaking…"
                let utterance = AVSpeechUtterance(string: reply)
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                currentUtterance = utterance
                synthesizer.speak(utterance)
            } catch is CancellationError { return }
            catch {
                guard round == id else { return }
                round = nil
                busy = false
                status = error.localizedDescription
            }
        }
    }

    func cancel() {
        guard modelReady else { return }
        round = nil
        source = nil
        deadline?.cancel()
        work?.cancel()
        recorder.discard()
        listening = false
        busy = processing
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        status = processing ? "Cancelling voice…" : "Voice ready — hold ⌃⌥Space"
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                      didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.currentUtterance.map(ObjectIdentifier.init) == utteranceID else { return }
            self.currentUtterance = nil
            self.status = "Voice ready — hold ⌃⌥Space"
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        hotKey.stop()
        work?.cancel()
        cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }
}
```

## Wave/VoiceInfo.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSMicrophoneUsageDescription</key>
    <string>Wave uses the microphone for push-to-talk voice commands. Audio is transcribed on-device and never stored.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
```

## Scripts/prepare-voice-model.sh

```sh
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../Wave/VoiceModels"
download() {
  mkdir -p "$(dirname "$2")"
  curl --fail --location --retry 3 "$1" -o "$2"
}
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/analytics/coremldata.bin" "AudioEncoder.mlmodelc/analytics/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/coremldata.bin" "AudioEncoder.mlmodelc/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/metadata.json" "AudioEncoder.mlmodelc/metadata.json"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/model.mil" "AudioEncoder.mlmodelc/model.mil"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/model.mlmodel" "AudioEncoder.mlmodelc/model.mlmodel"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/AudioEncoder.mlmodelc/weights/weight.bin" "AudioEncoder.mlmodelc/weights/weight.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/MelSpectrogram.mlmodelc/analytics/coremldata.bin" "MelSpectrogram.mlmodelc/analytics/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/MelSpectrogram.mlmodelc/coremldata.bin" "MelSpectrogram.mlmodelc/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/MelSpectrogram.mlmodelc/metadata.json" "MelSpectrogram.mlmodelc/metadata.json"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/MelSpectrogram.mlmodelc/model.mil" "MelSpectrogram.mlmodelc/model.mil"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/MelSpectrogram.mlmodelc/weights/weight.bin" "MelSpectrogram.mlmodelc/weights/weight.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/analytics/coremldata.bin" "TextDecoder.mlmodelc/analytics/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/coremldata.bin" "TextDecoder.mlmodelc/coremldata.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/metadata.json" "TextDecoder.mlmodelc/metadata.json"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/model.mil" "TextDecoder.mlmodelc/model.mil"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/model.mlmodel" "TextDecoder.mlmodelc/model.mlmodel"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/TextDecoder.mlmodelc/weights/weight.bin" "TextDecoder.mlmodelc/weights/weight.bin"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/config.json" "config.json"
download "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-base.en/generation_config.json" "generation_config.json"
download "https://huggingface.co/openai/whisper-base.en/resolve/911407f4214e0e1d82085af863093ec0b66f9cd6/tokenizer.json" "tokenizer.json"
download "https://huggingface.co/openai/whisper-base.en/resolve/911407f4214e0e1d82085af863093ec0b66f9cd6/tokenizer_config.json" "tokenizer_config.json"
shasum -a 256 -c ../../Scripts/voice-model.sha256
```

## Setup and verification

# Wave Phase 1b: local push-to-talk

Open `Wave/Wave.xcodeproj` in this checkout (`~/Downloads/wave-mac`). This is the updated copy; the separate `~/wave-mac` copy from Phase 0 is not updated.

## Test it

1. Build and run Wave in Xcode 26.x on an Apple Silicon Mac. Wait for **Voice ready — hold ⌃⌥Space** in the menu; the first Core ML load can take longer.
2. Set **Gesture mode: Off**. Voice uses no camera or gesture state.
3. Focus another app, hold **Control–Option–Space**, and grant microphone access if asked. If you released the keys while granting permission, press and hold them again.
4. Say **“hello wave”**, then release Space (or either modifier). Wave shows **Listening...**, then **Transcribing…**, **Asking Wave…**, and **Speaking…**; the reply is spoken using the local system voice.
5. Alternatively choose **Test voice**, speak during its five-second recording, and wait for the reply. The backend and Ollama must be running locally. A connection failure shows **Backend not reachable**.

The global shortcut uses an active Core Graphics event tap and the existing Accessibility grant. The chord is consumed so it does not type spaces into the focused app. Key repeats do not start additional recordings. Secure-input fields or another app's shortcut interception can prevent global key delivery; test in an ordinary text editor or browser page.

## Swift Package Manager

The dependency is already added and pinned in the project.

1. In Xcode choose **File → Add Package Dependencies…**.
2. Enter `https://github.com/argmaxinc/argmax-oss-swift.git`.
3. Choose **Exact Version: 1.1.0**.
4. Add only the **WhisperKit** product to the **Wave** target. Keep the existing MediaPipe product.
5. Leave the target at macOS 14.0, arm64, Swift 5, and nonisolated default actor isolation.

Package choice: **Argmax WhisperKit**, the native Swift/Core ML Whisper implementation maintained in Argmax OSS. Its stable 1.1.0 release has Apple Silicon support and a native in-memory transcription API. Wave links WhisperKit and its internal ArgmaxCore target. The package manifest also resolves Apple's `swift-argument-parser` for Argmax's CLI; that product is not linked into Wave. No additional application dependencies were added.

Sources: [Argmax OSS](https://github.com/argmaxinc/argmax-oss-swift), [1.1.0 release](https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.0).

## Offline model assets

`Wave/VoiceModels/` is already populated and copied into Wave.app as a folder resource. It contains the English `openai_whisper-base.en` Core ML model and local tokenizer, approximately 155 MB. Model preparation/downloads happen during development, not in the running app. Audio and transcription never go to a cloud API.

To reconstruct the assets from their pinned upstream revisions, run this from the checkout root, then rebuild:

```sh
bash Scripts/prepare-voice-model.sh
```

The script downloads static model/tokenizer files from Hugging Face. It never accesses the microphone. Do not move the model files into the Swift source group: keep the existing `VoiceModels` folder reference in Copy Bundle Resources. The app checks for local assets, validates the tokenizer, and sets WhisperKit `download: false`; missing or corrupt assets produce a menu error instead of starting a recording.

## Files

All Swift files below belong to the Wave app target and live in `Wave/Wave/`:

- `WaveApp.swift`: existing menu and lifecycle with independent voice state, microphone icon, Test voice, Cancel voice, and permission/retry actions.
- `VoiceHotKey.swift`: global Control–Option–Space event tap, repeat suppression, modifier release handling, and recovery after tap disablement.
- `VoiceRecorder.swift`: AVAudioEngine capture, mono 16 kHz conversion, lock-protected in-memory PCM, and bounded recording length.
- `LocalTranscriber.swift`: actor-isolated WhisperKit model loading and transcription of the PCM array.
- `VoiceBackend.swift`: ephemeral URLSession POST to `127.0.0.1:4000/ask`, JSON decoding, timeout/errors, and redirect rejection.
- `VoiceModel.swift`: microphone permission, recording/transcription/request/speech lifecycle, five-second menu test, cancellation, and AVSpeechSynthesizer.

Other files:

- `Wave/VoiceInfo.plist`: microphone description and local-network transport setting; Xcode merges it with the existing generated Info.plist values.
- `Wave/Wave.xcodeproj/project.pbxproj`: WhisperKit dependency, model resource, microphone entitlement build setting, and plist path.
- `Scripts/prepare-voice-model.sh`: reproducible developer-only asset download.
- `Tests/VoiceBackendChecks.swift`: dependency-free checks for backend success and failure handling.
- `Tests/VoiceTranscriptionSmoke.swift`: generated-audio transcription and local backend smoke test.
- `VOICE_CODE.md`: complete new/updated Swift source, file by file, with plist and model preparation script.

The Phase 0 `HandCamera.swift`, `GestureEngine.swift`, and `WaveModel.swift` are unchanged.

## Info.plist and capabilities

`Wave/VoiceInfo.plist` contains:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Wave uses the microphone for push-to-talk voice commands. Audio is transcribed on-device and never stored.</string>
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

Existing `LSUIElement = true` and `NSCameraUsageDescription` stay configured in target build settings. Hardened Runtime has **Audio Input** enabled (`ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES`), alongside the existing Camera resource access. App Sandbox remains disabled for global cursor/hotkey handling. Apple Speech Recognition permission is not requested: WhisperKit does transcription locally.

## Behavior

- The microphone opens only for a held shortcut or the menu test. Audio is held in RAM, passed directly to WhisperKit, then released; no recording file is written. Model weights/tokenizer remain on disk.
- Releasing during the permission prompt cancels that round. It cannot start recording unexpectedly after permission is granted.
- Only one round runs at a time. Recording stops after at most 30 seconds, on cancellation, on sleep, or on microphone reconfiguration. Test voice stops after five seconds.
- New recording interrupts a spoken reply. Key presses during transcription or the backend request are ignored. Cancel voice discards the round and prevents a late reply from speaking.
- Silence/very short input is rejected. Whisper is probabilistic; noisy audio can still produce mistaken text.
- Only `{ "text": "…" }` reaches the localhost backend. Network sessions are ephemeral, and HTTP redirects are rejected. Backend timeout is 90 seconds per request / 95 seconds overall because the current local model can take roughly 40 seconds.
- Permission denial appears in the menu with an **Open Microphone Settings…** action. Enable Wave in Privacy & Security → Microphone; quit/reopen if macOS requests it.

## Verified results

- Xcode 26.6 Debug arm64 build: **BUILD SUCCEEDED**, with no Swift compiler errors or warnings. Xcode emits its standard App Intents metadata notice because this app has no App Intents dependency.
- Phase 0 gesture regression checks: passed.
- Voice backend checks: successful decoding, invalid JSON, empty response, HTTP failure, and connection failure passed.
- Local WhisperKit test on generated system-voice audio: `TRANSCRIPT: Hello Wave`.
- That transcript sent to the real local backend returned: `REPLY: Hello! I'm Wave. How can I help you today?`.
- Live microphone capture, global shortcut interaction, and audible AVSpeechSynthesizer output still require the hands-on steps above. The automated test used generated speech and did not access the camera or microphone.

Run the dependency-free backend and gesture checks from the checkout root:

```sh
xcrun swiftc Wave/Wave/VoiceBackend.swift Wave/Wave/VoiceRecorder.swift Tests/VoiceBackendChecks.swift -o /tmp/wave-backend-checks
/tmp/wave-backend-checks
xcrun swiftc Wave/Wave/GestureEngine.swift Tests/main.swift -o /tmp/wave-gesture-tests
/tmp/wave-gesture-tests
```
