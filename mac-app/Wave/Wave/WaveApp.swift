import SwiftUI

@main
struct WaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            WaveMenu(
                model: delegate.model,
                voice: delegate.voice,
                selector: delegate.model.selector,
                actions: delegate.voice.actions,
                buddyPill: delegate.buddyPill,
                launchManager: delegate.launchManager,
                chatModel: delegate.chatModel
            )
        } label: {
            VoiceMenuLabel(voice: delegate.voice)
        }
    }
}

private struct WaveMenu: View {
    @ObservedObject var model: WaveModel
    @ObservedObject var voice: VoiceModel
    @ObservedObject var selector: PointSelector
    @ObservedObject var actions: ActionRunner
    @ObservedObject var buddyPill: BuddyPillController
    @ObservedObject var launchManager: LaunchAtLoginManager
    @ObservedObject var chatModel: ChatSessionModel

    var body: some View {
        Toggle(model.modeTitle, isOn: Binding(
            get: { model.isActive },
            set: { model.setEnabled($0) }
        ))
        Toggle("Follow cursor with hand", isOn: Binding(
            get: { model.followCursor }, set: { model.setFollowCursor($0) }
        ))
        Toggle("Launch at Login", isOn: Binding(
            get: { launchManager.isEnabled }, set: { launchManager.setEnabled($0) }
        ))
        Menu("Ball Color: \(buddyPill.theme.rawValue)") {
            ForEach(BallColorTheme.allCases) { theme in
                Button(action: { buddyPill.setTheme(theme) }) {
                    if buddyPill.theme == theme {
                        Text("✓ \(theme.rawValue)")
                    } else {
                        Text(theme.rawValue)
                    }
                }
            }
        }
        Button("Reset Ball Position") { buddyPill.resetPosition() }
        Text(model.followCursor ? "Hand-driven cursor mode" : "Point-to-select mode")
        Text(model.status)
        Text(selector.message)
        if selector.target != nil {
            Button("Dismiss highlight") { selector.dismiss() }
        }
        if !model.accessibilityGranted {
            Button("Open Accessibility Settings…") { model.openAccessibility() }
        }
        Divider()
        brainPickerMenu
        Text("Active brain: \(voice.brain)")
        Text(voice.status)
        Text(actions.status)
        Menu("Action log") {
            if actions.log.isEmpty { Text("No actions yet") }
            ForEach(Array(actions.log.enumerated()), id: \.offset) { _, entry in Text(entry) }
        }
        Text("Push to talk: ⌃⌥Space")
        if !voice.hotKeyAvailable {
            Text("Voice hotkey needs Accessibility permission")
        }
        Divider()
        Toggle("Wake Word ('Hey Wave')", isOn: Binding(
            get: { voice.wakeWordEnabled },
            set: { voice.setWakeWordEnabled($0) }
        ))
        if voice.wakeWordEnabled {
            Text(voice.wakeWordListener.isListening ? "Listening for 'Hey Wave'" : "Wake Word: Initializing…")
            Text("Engine: \(voice.wakeWordListener.activeEngineName)")
        } else {
            Text("Wake Word: Off")
        }
        Menu("Wake Word Settings") {
            Button("Set Porcupine AccessKey…") {
                promptForAccessKey()
            }
            if let customKey = UserDefaults.standard.string(forKey: "porcupine_access_key"), !customKey.isEmpty {
                Text("AccessKey: ••••••••\(customKey.suffix(4))")
                Button("Clear AccessKey") {
                    UserDefaults.standard.removeObject(forKey: "porcupine_access_key")
                    voice.wakeWordListener.rebuildEngine()
                }
            } else {
                Text("No AccessKey set (using local on-device engine)")
            }
            Divider()
            Menu("Sensitivity: \(String(format: "%.2f", UserDefaults.standard.double(forKey: "wake_word_sensitivity") > 0 ? UserDefaults.standard.double(forKey: "wake_word_sensitivity") : 0.45))") {
                Button("Low (0.35)") { setSensitivity(0.35) }
                Button("Conservative (0.45 - Default)") { setSensitivity(0.45) }
                Button("Medium (0.55)") { setSensitivity(0.55) }
                Button("High (0.65)") { setSensitivity(0.65) }
            }
        }
        Divider()
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

    private func promptForAccessKey() {
        let alert = NSAlert()
        alert.messageText = "Porcupine AccessKey"
        alert.informativeText = "Enter your free Picovoice AccessKey from console.picovoice.ai to enable hardware-accelerated wake word detection:"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = UserDefaults.standard.string(forKey: "porcupine_access_key") ?? ""
        input.placeholderString = "Paste AccessKey here..."
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                UserDefaults.standard.removeObject(forKey: "porcupine_access_key")
            } else {
                UserDefaults.standard.set(key, forKey: "porcupine_access_key")
            }
            voice.wakeWordListener.rebuildEngine()
            if voice.wakeWordEnabled {
                voice.wakeWordListener.start()
            }
        }
    }

    private func setSensitivity(_ value: Double) {
        UserDefaults.standard.set(value, forKey: "wake_word_sensitivity")
        voice.wakeWordListener.rebuildEngine()
        if voice.wakeWordEnabled {
            voice.wakeWordListener.start()
        }
    }

    private var brainPickerMenu: some View {
        Menu("Brain: \(chatModel.brainChoice.displayTitle)") {
            Button(action: { chatModel.setBrainChoice(.auto) }) {
                if chatModel.brainChoice == .auto {
                    Text("✓ Auto (Recommended)")
                } else {
                    Text("Auto (Recommended)")
                }
            }
            Button(action: { chatModel.setBrainChoice(.preferCloud) }) {
                if chatModel.brainChoice == .preferCloud {
                    Text("✓ Prefer Cloud")
                } else {
                    Text("Prefer Cloud")
                }
            }
            Button(action: { chatModel.setBrainChoice(.preferLocal) }) {
                if chatModel.brainChoice == .preferLocal {
                    Text("✓ Prefer Local")
                } else {
                    Text("Prefer Local")
                }
            }

            Divider()

            Menu("Cloud Models") {
                if chatModel.cloudModels.isEmpty {
                    Text("No cloud models available")
                } else {
                    ForEach(chatModel.cloudModels, id: \.self) { modelId in
                        Button(action: { chatModel.setBrainChoice(.specificCloud(modelId)) }) {
                            if chatModel.brainChoice == .specificCloud(modelId) {
                                Text("✓ \(modelId)")
                            } else {
                                Text(modelId)
                            }
                        }
                    }
                }
            }

            Menu("Local Models") {
                if chatModel.localModels.isEmpty {
                    Text("No local models found (Ollama offline)")
                } else {
                    ForEach(chatModel.localModels, id: \.self) { modelName in
                        Button(action: { chatModel.setBrainChoice(.specificLocal(modelName)) }) {
                            if chatModel.brainChoice == .specificLocal(modelName) {
                                Text("✓ \(modelName)")
                            } else {
                                Text(modelName)
                            }
                        }
                    }
                }
            }

            Divider()

            Button("Refresh Models") {
                Task { await chatModel.fetchModels() }
            }
        }
    }
}

private struct VoiceMenuLabel: View {
    @ObservedObject var voice: VoiceModel
    var body: some View {
        Label(voice.listening ? "Listening..." : "Wave",
              systemImage: voice.listening ? "mic.fill" : (voice.wakeWordEnabled ? "waveform.badge.mic" : "hand.wave.fill"))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = WaveModel()
    let voice = VoiceModel()
    let notchHUD = NotchHUD()
    let buddyPill = BuddyPillController()
    let waveCursor = WaveCursorController()
    let launchManager = LaunchAtLoginManager()
    let chatModel = ChatSessionModel()
    private(set) var chatController: WaveChatController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let chatCtrl = WaveChatController(chatModel: chatModel)
        self.chatController = chatCtrl
        chatModel.setVoiceModel(voice)
        voice.chatSession = chatModel
        buddyPill.chatController = chatCtrl

        model.selector.buddyPill = buddyPill
        voice.actions.waveCursor = waveCursor
        voice.actions.buddyPill = buddyPill
        voice.selectedTarget = { [weak model] in model?.selector.target }
        voice.selectionFinished = { [weak model] in model?.selector.dismiss() }
        model.selector.canSelect = { [weak voice] in voice?.busy == false && voice?.actions.running == false }
        model.selector.onSelected = { [weak voice] in voice?.promptForTarget() }
        voice.onWakeAcknowledge = { [weak buddyPill] in
            buddyPill?.pulseWakeWord()
        }
        voice.onTaskCompleted = { [weak buddyPill] in
            buddyPill?.triggerDone()
        }
        model.start()
        voice.start()
        // Notch HUD presentation stopped; visual feedback handled exclusively by the Living Ball companion
        buddyPill.start(voice: voice, actions: voice.actions)
        launchManager.configureOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        voice.stop()
        notchHUD.hide()
        waveCursor.emergencyRestore()
    }
}
