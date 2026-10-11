import AppKit
import AVFoundation
import Combine

@MainActor
final class VoiceModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, VoiceCommandExecuting {
    @Published private(set) var status = "Preparing voice model…"
    @Published private(set) var listening = false
    @Published private(set) var busy = true
    @Published private(set) var hotKeyAvailable = false
    @Published private(set) var microphoneDenied = false
    @Published private(set) var modelReady = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var audioLevel: Float = 0
    @Published var wakeWordEnabled = UserDefaults.standard.bool(forKey: "wake_word_enabled")
    @Published private(set) var wakeWordStatus = "Wake Word: Off"
    @Published private(set) var brain = "Cloud"
    let actions = ActionRunner()
    let wakeWordListener = WakeWordListener()
    var onWakeAcknowledge: (() -> Void)?
    var onTaskCompleted: (() -> Void)?
    var selectedTarget: () -> SelectedTarget? = { nil }
    var selectionFinished: (() -> Void)?
    weak var chatSession: ChatSessionModel?
    private var roundTarget: SelectedTarget?
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
    private enum InputSource { case hotKey, menuTest, promptFollowUp, wakeWord, pillClick }

    var readyStatus: String {
        wakeWordEnabled ? "Listening for 'Hey Wave'" : "Voice ready — hold ⌃⌥Space"
    }

    func toggleListening() {
        if listening {
            finish()
        } else if modelReady && !busy && round == nil {
            begin(.pillClick)
        }
    }

    func setWakeWordEnabled(_ on: Bool) {
        wakeWordEnabled = on
        UserDefaults.standard.set(on, forKey: "wake_word_enabled")
        if on {
            if modelReady && !busy && !listening {
                wakeWordListener.start()
                status = readyStatus
            }
        } else {
            wakeWordListener.stop()
            status = readyStatus
        }
    }

    func start() {
        synthesizer.delegate = self
        recorder.onAudioLevel = { [weak self] lvl in
            self?.audioLevel = lvl
        }
        wakeWordListener.onWakeDetected = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleWakeWordActivation()
            }
        }
        wakeWordListener.statusChanged = { [weak self] newStatus in
            Task { @MainActor [weak self] in
                self?.wakeWordStatus = newStatus
            }
        }
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
                if wakeWordEnabled {
                    wakeWordListener.start()
                }
                status = readyStatus
            } catch is CancellationError { return }
            catch { status = "Voice unavailable: \(error.localizedDescription)" }
            busy = false
        }
    }

    func testVoice() { begin(.menuTest) }

    func handleWakeWordActivation() {
        guard modelReady, !busy, round == nil else { return }
        NSSound(named: "Tink")?.play()
        onWakeAcknowledge?()
        begin(.wakeWord)
    }

    func promptForTarget() {
        guard !busy, !listening else { return }
        let app = selectedTarget()?.context.app ?? "App"
        let promptText = "\(app): what do you want to do?"
        status = promptText
        let utterance = AVSpeechUtterance(string: promptText)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        currentUtterance = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    private func begin(_ inputSource: InputSource) {
        guard modelReady, !busy, round == nil else { return }
        wakeWordListener.pause()
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        let id = UUID()
        roundTarget = selectedTarget()
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
                if wakeWordEnabled {
                    wakeWordListener.resume()
                }
                return
            }
            do {
                if inputSource == .promptFollowUp || inputSource == .wakeWord || inputSource == .pillClick {
                    recorder.onSilenceAfterSpeech = { [weak self] in
                        self?.finish()
                    }
                } else {
                    recorder.onSilenceAfterSpeech = nil
                }
                try recorder.start()
                listening = true
                status = (inputSource == .wakeWord || inputSource == .pillClick) ? "Listening for command…" : "Listening..."
                let seconds: Double
                switch inputSource {
                case .menuTest: seconds = 5.0
                case .promptFollowUp: seconds = 6.5
                case .wakeWord, .pillClick: seconds = 10.0
                case .hotKey: seconds = VoiceRecorder.maxSeconds
                }
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
                if wakeWordEnabled {
                    wakeWordListener.resume()
                }
            }
        }
    }

    private func finish() {
        guard let id = round else { return }
        deadline?.cancel()
        deadline = nil
        guard listening else { cancel(); return }
        listening = false
        audioLevel = 0
        source = nil
        let samples: [Float]
        do { samples = try recorder.finish() }
        catch {
            cancel()
            status = error.localizedDescription
            if wakeWordEnabled {
                wakeWordListener.resume()
            }
            return
        }
        status = "Transcribing…"
        processing = true
        let target = roundTarget
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                processing = false
                if round == nil {
                    busy = false
                    if Task.isCancelled {
                        status = readyStatus
                        if wakeWordEnabled {
                            wakeWordListener.resume()
                        }
                    }
                }
            }
            do {
                let text = try await transcriber.transcribe(samples)
                chatSession?.addMessage(role: .user, text: text)
                try Task.checkCancellation()
                guard round == id else { return }
                status = "Asking Wave…"
                let requestedModel = chatSession?.activeModelParameter
                let requestedSessionId = chatSession?.currentSessionId
                let response = try await VoiceBackend().agent(text, model: requestedModel, sessionId: requestedSessionId, target: target?.context)
                if let sid = response.session_id {
                    chatSession?.currentSessionId = sid
                }
                if let m = response.model {
                    self.brain = (m.lowercased() == "cloud") ? "Cloud" : "Local"
                }
                try Task.checkCancellation()
                guard round == id else { return }
                status = "Doing that…"
                let failure = await actions.run(response, target: target)
                try Task.checkCancellation()
                guard round == id else { return }
                if failure == nil && !response.actions.isEmpty {
                    selectionFinished?()
                    onTaskCompleted?()
                } else if failure == nil && !response.reply.isEmpty {
                    onTaskCompleted?()
                }
                roundTarget = nil
                round = nil
                busy = false
                status = "Speaking…"

                let spokenReply: String
                if let failure {
                    spokenReply = failure
                } else if let last = actions.lastResult, !response.actions.isEmpty {
                    if case .install = response.actions.last {
                        spokenReply = last
                    } else {
                        spokenReply = response.reply.isEmpty ? last : response.reply
                    }
                } else {
                    spokenReply = response.reply
                }

                chatSession?.addMessage(role: .assistant, text: spokenReply, model: response.model)

                if spokenReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    status = readyStatus
                    if wakeWordEnabled {
                        wakeWordListener.resume()
                    }
                    return
                }

                let utterance = AVSpeechUtterance(string: spokenReply)
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                currentUtterance = utterance
                isSpeaking = true
                synthesizer.speak(utterance)
            } catch is CancellationError {
                if wakeWordEnabled {
                    wakeWordListener.resume()
                }
                return
            }
            catch {
                guard round == id else { return }
                round = nil
                busy = false
                status = error.localizedDescription
                if wakeWordEnabled {
                    wakeWordListener.resume()
                }
            }
        }
    }

    func cancel() {
        guard modelReady else { return }
        round = nil
        roundTarget = nil
        source = nil
        deadline?.cancel()
        work?.cancel()
        recorder.discard()
        listening = false
        audioLevel = 0
        busy = processing
        currentUtterance = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
        selectionFinished?()
        status = processing ? "Cancelling voice…" : readyStatus
        if wakeWordEnabled && !processing {
            wakeWordListener.resume()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                      didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.currentUtterance.map(ObjectIdentifier.init) == utteranceID else { return }
            self.currentUtterance = nil
            self.isSpeaking = false
            if self.selectedTarget() != nil {
                // Target confirmed: automatically transition to hands-free listening!
                self.begin(.promptFollowUp)
            } else {
                self.status = self.readyStatus
                if self.wakeWordEnabled {
                    self.wakeWordListener.resume()
                }
            }
        }
    }

    func executeTypedCommand(_ text: String, model: String, sessionId: String? = nil) async {
        guard !busy else { return }
        wakeWordListener.pause()
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        busy = true
        status = "Asking Wave…"
        let target = selectedTarget()

        do {
            let response = try await VoiceBackend().agent(text, model: model, sessionId: sessionId, target: target?.context)
            if let sid = response.session_id {
                chatSession?.currentSessionId = sid
            }
            if let m = response.model {
                self.brain = (m.lowercased() == "cloud") ? "Cloud" : "Local"
            }
            status = "Doing that…"
            let failure = await actions.run(response, target: target)
            if failure == nil && !response.actions.isEmpty {
                selectionFinished?()
                onTaskCompleted?()
            } else if failure == nil && !response.reply.isEmpty {
                onTaskCompleted?()
            }
            busy = false
            status = "Speaking…"

            let spokenReply: String
            if let failure {
                spokenReply = failure
            } else if let last = actions.lastResult, !response.actions.isEmpty {
                if case .install = response.actions.last {
                    spokenReply = last
                } else {
                    spokenReply = response.reply.isEmpty ? last : response.reply
                }
            } else {
                spokenReply = response.reply
            }

            chatSession?.addMessage(role: .assistant, text: spokenReply, model: response.model)

            if !spokenReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let utterance = AVSpeechUtterance(string: spokenReply)
                utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                currentUtterance = utterance
                isSpeaking = true
                synthesizer.speak(utterance)
            } else {
                status = readyStatus
                if wakeWordEnabled {
                    wakeWordListener.resume()
                }
            }
        } catch {
            busy = false
            status = error.localizedDescription
            chatSession?.addMessage(role: .assistant, text: "Sorry, I couldn't reach the model right now.")
            if wakeWordEnabled {
                wakeWordListener.resume()
            }
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        hotKey.stop()
        wakeWordListener.stop()
        work?.cancel()
        cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }
}
