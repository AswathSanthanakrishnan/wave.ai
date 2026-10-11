import Foundation
import CoreGraphics

func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

@MainActor
func testChatSessionModelLogic() {
    print("Testing ChatSessionModel logic...")

    // 1. Message struct
    let msg1 = ChatMessage(role: .user, text: "open Notes")
    check(msg1.role == .user, "User role check")
    check(msg1.text == "open Notes", "User message text")
    check(msg1.model == nil, "User message model check")

    let msg2 = ChatMessage(role: .assistant, text: "Opening Notes for you.", model: "cloud")
    check(msg2.role == .assistant, "Assistant role check")
    check(msg2.text == "Opening Notes for you.", "Assistant message text")
    check(msg2.model == "cloud", "Assistant message model check")

    // 2. Active model parameter string formatting & BrainChoice
    let choiceAuto = BrainChoice.auto
    check(choiceAuto.modelParameter == "auto", "Auto parameter check")
    let choiceCloud = BrainChoice.preferCloud
    check(choiceCloud.modelParameter == "cloud", "Prefer Cloud parameter check")
    let choiceLocal = BrainChoice.preferLocal
    check(choiceLocal.modelParameter == "local", "Prefer Local parameter check")
    let choiceSpecificCloud = BrainChoice.specificCloud("openai/gpt-oss-120b")
    check(choiceSpecificCloud.modelParameter == "cloud:openai/gpt-oss-120b", "Specific cloud parameter check")
    let choiceSpecificLocal = BrainChoice.specificLocal("ornith:9b")
    check(choiceSpecificLocal.modelParameter == "local:ornith:9b", "Specific local parameter check")

    // 3. Panel docking offset calculation
    let ballFrame = CGRect(x: 1000, y: 400, width: 84, height: 84)
    let panelSize = CGSize(width: 340, height: 460)
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    var targetX = ballFrame.maxX + 12
    var targetY = ballFrame.midY - panelSize.height / 2

    if targetX + panelSize.width > screen.maxX - 8 {
        targetX = ballFrame.minX - panelSize.width - 12
    }
    targetX = max(screen.minX + 8, min(targetX, screen.maxX - panelSize.width - 8))
    targetY = max(screen.minY + 8, min(targetY, screen.maxY - panelSize.height - 8))

    check(targetX > 0 && targetX + panelSize.width <= screen.maxX, "Panel docked horizontally on screen")
    check(targetY > 0 && targetY + panelSize.height <= screen.maxY, "Panel docked vertically on screen")

    // 4. Session management & New Chat logic
    let chatModel = ChatSessionModel()
    chatModel.addMessage(role: .user, text: "hello")
    chatModel.currentSessionId = "test-uuid-1234"
    chatModel.currentSessionTitle = "hello"
    check(chatModel.messages.count == 1, "Message added")
    check(chatModel.currentSessionId == "test-uuid-1234", "Session ID set")

    chatModel.startNewChat()
    check(chatModel.messages.isEmpty, "Messages cleared on startNewChat")
    check(chatModel.currentSessionId == nil, "Session ID reset on startNewChat")
    check(chatModel.currentSessionTitle == nil, "Session Title reset on startNewChat")

    // 5. Session item decodability check
    let summaryJSON = """
    {"id":"01923e4b-3b7d-7000-8000-000000000000","title":"open Notes","created_at":"2026-09-24T19:00:00Z"}
    """.data(using: .utf8)!
    let summary = try! JSONDecoder().decode(VoiceBackend.SessionSummaryItem.self, from: summaryJSON)
    check(summary.id == "01923e4b-3b7d-7000-8000-000000000000", "Summary id decoded")
    check(summary.title == "open Notes", "Summary title decoded")

    print("PASS: ChatSessionModel messages, active model parameter format, docking bounds, and session management.")
}

@main
@MainActor
struct ChatPanelChecks {
    static func main() {
        testChatSessionModelLogic()
    }
}
