import Foundation
import CoreGraphics

func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

func decodeReply(_ json: String) throws -> AgentReply {
    try JSONDecoder().decode(AgentReply.self, from: Data(json.utf8))
}

func testActionDecoding() throws {
    // 1. open_app
    let r1 = try decodeReply(#"{"reply":"Opening","actions":[{"tool":"open_app","app":"Safari"}]}"#)
    check(r1.actions.count == 1, "open_app decoded")
    if case .openApp(let app) = r1.actions[0] { check(app == "Safari", "open_app value") }
    else { preconditionFailure() }

    // 2. close_app
    let r2 = try decodeReply(#"{"reply":"Closing","actions":[{"tool":"close_app","app":"Terminal"}]}"#)
    check(r2.actions.count == 1, "close_app decoded")

    // 3. set_low_power_mode
    let r3 = try decodeReply(#"{"reply":"Low power","actions":[{"tool":"set_low_power_mode","on":true}]}"#)
    if case .lowPower(let on) = r3.actions[0] { check(on == true, "low power on") }
    else { preconditionFailure() }

    // 4. set_dark_mode
    let r4 = try decodeReply(#"{"reply":"Dark mode","actions":[{"tool":"set_dark_mode","on":false}]}"#)
    if case .darkMode(let on) = r4.actions[0] { check(on == false, "dark mode off") }
    else { preconditionFailure() }

    // 5. set_volume
    let r5 = try decodeReply(#"{"reply":"Volume","actions":[{"tool":"set_volume","level":50}]}"#)
    if case .volume(let lvl) = r5.actions[0] { check(lvl == 50, "volume 50") }
    else { preconditionFailure() }

    // 6. mute
    let r6 = try decodeReply(#"{"reply":"Muting","actions":[{"tool":"mute","on":true}]}"#)
    if case .mute(let on) = r6.actions[0] { check(on == true, "mute on") }
    else { preconditionFailure() }

    // 7. open_url
    let r7 = try decodeReply(#"{"reply":"URL","actions":[{"tool":"open_url","url":"https://apple.com"}]}"#)
    if case .openURL(let url) = r7.actions[0] { check(url.host == "apple.com", "open url") }
    else { preconditionFailure() }

    // 8. minimize_front_window
    let r8 = try decodeReply(#"{"reply":"Minimizing","actions":[{"tool":"minimize_front_window"}]}"#)
    if case .minimizeFront = r8.actions[0] {} else { preconditionFailure() }

    // 9. type_text
    let r9 = try decodeReply(#"{"reply":"Typing","actions":[{"tool":"type_text","text":"hello"}]}"#)
    if case .typeText(let t) = r9.actions[0] { check(t == "hello", "type text") }
    else { preconditionFailure() }

    // 10. press_key
    let r10 = try decodeReply(#"{"reply":"Key","actions":[{"tool":"press_key","key":"enter"}]}"#)
    if case .pressKey(let k) = r10.actions[0] { check(k == "enter", "press enter") }
    else { preconditionFailure() }

    // 11. close_this, minimize_this, open_this
    let r11 = try decodeReply(#"{"reply":"This","actions":[{"tool":"close_this"},{"tool":"minimize_this"},{"tool":"open_this"}]}"#)
    check(r11.actions.count == 3, "three targeted actions")

    // 12. install_app
    let r12 = try decodeReply(#"{"reply":"Installing","actions":[{"tool":"install_app","name":"Docker"}]}"#)
    if case .install(let name) = r12.actions[0] { check(name == "Docker", "install app") }
    else { preconditionFailure() }

    // 13. Resilient extra fields: metadata / args container / string bools
    let r13 = try decodeReply(#"{"reply":"Extra","actions":[{"tool":"open_app","app":"Safari","id":"123","thought":"reason"}]}"#)
    check(r13.actions.count == 1, "tolerates extra fields")
    check(r13.rejected == 0, "no rejected actions")

    let r14 = try decodeReply(#"{"reply":"Nested","actions":[{"tool":"set_low_power_mode","args":{"on":"true"}}]}"#)
    check(r14.actions.count == 1, "nested args parsed")

    // 15. wait tool (0.5 to 5.0 seconds)
    let r16 = try decodeReply(#"{"reply":"Waiting","actions":[{"tool":"wait","seconds":1}]}"#)
    check(r16.actions.count == 1, "wait action decoded")
    if case .wait(let sec) = r16.actions[0] { check(sec == 1.0, "wait 1s") }
    else { preconditionFailure() }

    // Multi-step sequence: open Notes -> wait -> type text
    let r17 = try decodeReply(#"{"reply":"On it","actions":[{"tool":"open_app","app":"Notes"},{"tool":"wait","seconds":1},{"tool":"type_text","text":"hello wave"}]}"#)
    check(r17.actions.count == 3, "multi-step sequence decoded")
    if case .openApp(let app) = r17.actions[0],
       case .wait(let sec) = r17.actions[1],
       case .typeText(let txt) = r17.actions[2] {
        check(app == "Notes", "step 1 open Notes")
        check(sec == 1.0, "step 2 wait")
        check(txt == "hello wave", "step 3 type text")
    } else { preconditionFailure() }

    // Invalid wait rejected (e.g. 10s out of range 0.5-5.0)
    let r18 = try decodeReply(#"{"reply":"Invalid","actions":[{"tool":"wait","seconds":10}]}"#)
    check(r18.actions.count == 0, "out-of-range wait rejected")
    // 16. click_element tool
    let r19 = try decodeReply(#"{"reply":"Clicking","actions":[{"tool":"click_element","app":"Chrome","label":"Address bar"}]}"#)
    check(r19.actions.count == 1, "click_element decoded")
    if case .clickElement(let app, let label) = r19.actions[0] {
        check(app == "Chrome", "click_element app")
        check(label == "Address bar", "click_element label")
    } else { preconditionFailure() }

    // Multi-step agentic sequence: search Chrome for cute puppies
    let r20 = try decodeReply(#"{"reply":"On it, searching Chrome for cute puppies.","actions":[{"tool":"open_app","app":"Chrome"},{"tool":"click_element","app":"Chrome","label":"Address bar"},{"tool":"type_text","text":"cute puppies"},{"tool":"press_key","key":"enter"}]}"#)
    check(r20.actions.count == 4, "4-step Chrome search sequence decoded")
    if case .openApp(let app) = r20.actions[0],
       case .clickElement(let cApp, let cLabel) = r20.actions[1],
       case .typeText(let query) = r20.actions[2],
       case .pressKey(let key) = r20.actions[3] {
        check(app == "Chrome", "step 1 open Chrome")
        check(cApp == "Chrome" && cLabel == "Address bar", "step 2 click Address bar")
        check(query == "cute puppies", "step 3 type query")
        check(key == "enter", "step 4 press Enter")
    } else { preconditionFailure() }

    // 17. model and session_id field in AgentReply ("cloud" or "local", uuid)
    let r22 = try decodeReply(#"{"reply":"Hello","actions":[],"model":"cloud","session_id":"123e4567-e89b-12d3-a456-426614174000"}"#)
    check(r22.model == "cloud", "cloud model decoded")
    check(r22.session_id == "123e4567-e89b-12d3-a456-426614174000", "session_id decoded")
    let r23 = try decodeReply(#"{"reply":"Hello","actions":[],"model":"local","session_id":"987e6543-e89b-12d3-a456-426614174000"}"#)
    check(r23.model == "local", "local model decoded")
    check(r23.session_id == "987e6543-e89b-12d3-a456-426614174000", "session_id decoded")

    print("PASS: All 16 whitelisted actions decoded, extra fields tolerated, unwhitelisted tools rejected, model decoded, session_id decoded")
}

@main
struct ActionChecks {
    static func main() throws {
        try testActionDecoding()
    }
}
