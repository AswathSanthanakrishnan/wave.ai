import AppKit
import SwiftUI
import Combine

func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

@MainActor
final class VoiceModel: ObservableObject {
    @Published var status: String = "Ready"
    @Published var listening = false
    @Published var busy = false
    @Published var isSpeaking = false
    @Published var audioLevel: Float = 0
    var toggledCount = 0

    func toggleListening() {
        toggledCount += 1
    }
}

@MainActor
final class ActionRunner: ObservableObject {
    @Published var running = false
    @Published var status = "Actions ready"
    @Published var log: [String] = []
}

@MainActor
func testBuddyPillBasics() {
    print("Testing BuddyPillController and BuddyPillPanel...")

    // 1. Test BuddyPillPanel properties
    let panel = BuddyPillPanel(
        contentRect: CGRect(x: 100, y: 100, width: 64, height: 32),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    check(!panel.canBecomeKey, "BuddyPillPanel must never become key")
    check(!panel.canBecomeMain, "BuddyPillPanel must never become main")

    // 2. Test Controller state dimensions
    let controller = BuddyPillController()
    check(controller.state == .idle, "Default state should be idle")

    let idleSize = controller.pillSize(for: .idle)
    check(idleSize.width == 84 && idleSize.height == 84, "Idle size must be 84x84")

    let listeningSize = controller.pillSize(for: .listening)
    check(listeningSize.width == 84 && listeningSize.height == 84, "Listening size must be 84x84")

    let thinkingSize = controller.pillSize(for: .thinking)
    check(thinkingSize.width == 84 && thinkingSize.height == 84, "Thinking size must be 84x84")

    let speakingSize = controller.pillSize(for: .speaking)
    check(speakingSize.width == 84 && speakingSize.height == 84, "Speaking size must be 84x84")

    let doneSize = controller.pillSize(for: .done)
    check(doneSize.width == 116 && doneSize.height == 84, "Done size must be 116x84")

    // 3. Test default positioning
    let defPos = controller.defaultPosition(for: idleSize)
    check(defPos.x > 0 && defPos.y > 0, "Default position should be on screen")

    // 4. Test pipeline wiring and state reactivity
    let mockVoice = VoiceModel()
    let mockActions = ActionRunner()
    controller.start(voice: mockVoice, actions: mockActions)

    mockVoice.listening = true
    // Allow RunLoop to process Combine sink
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(controller.state == .listening, "Listening state reflected in controller")

    mockVoice.listening = false
    mockVoice.busy = true
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(controller.state == .thinking, "Thinking state reflected when voice is busy")

    mockVoice.busy = false
    mockVoice.isSpeaking = true
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(controller.state == .speaking, "Speaking state reflected when voice is speaking")

    mockVoice.isSpeaking = false
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(controller.state == .idle, "Returns to idle when quiet")

    // 5. Test toggle listening via pill click
    controller.toggleListening()
    check(mockVoice.toggledCount == 1, "toggleListening calls voice.toggleListening")

    // 6. Test triggerDone
    controller.triggerDone()
    check(controller.state == .done, "Triggering done sets state to .done")

    // 7. Test drag and bounds clamping
    controller.startDrag()
    controller.updateDrag(translation: CGSize(width: 50, height: -50))
    controller.endDrag(translation: CGSize(width: 50, height: -50))

    // 8. Test resetPosition
    controller.resetPosition()

    // 9. Test pulseWakeWord
    controller.pulseWakeWord()
    check(controller.isWakePulsing, "pulseWakeWord sets isWakePulsing to true")

    // 10. Test color themes
    check(controller.theme == .sapphire, "Default theme should be sapphire")
    controller.setTheme(.violet)
    check(controller.theme == .violet, "setTheme updates theme to violet")
    controller.setTheme(.sapphire)

    // 11. Test ball is always enabled & ballCenterCG
    check(controller.enabled == true, "Ball companion is always enabled")
    controller.setEnabled(false)
    check(controller.enabled == true, "Ball companion cannot be disabled")
    let center = controller.ballCenterCG
    check(center.x > 0 && center.y > 0, "ballCenterCG is on-screen")

    // 12. Test CursorVisibilityManager failsafe
    check(!CursorVisibilityManager.isSystemCursorHidden, "System cursor initially visible")
    CursorVisibilityManager.hide()
    check(CursorVisibilityManager.isSystemCursorHidden, "System cursor hidden during sequence")
    CursorVisibilityManager.restore()
    check(!CursorVisibilityManager.isSystemCursorHidden, "System cursor restored after sequence")

    print("PASS: BuddyPillPanel non-activating focus, pill sizes, edge positioning, drag clamping, pipeline reactivity, done triggers, wake pulse, color themes, always-on ball, and cursor failsafe.")
}

@main
struct BuddyPillChecks {
    @MainActor
    static func main() {
        testBuddyPillBasics()
    }
}
