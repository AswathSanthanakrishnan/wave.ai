import AppKit
import ApplicationServices

@MainActor
enum LowPowerControl {
    static func set(_ on: Bool) async throws {
        guard AXIsProcessTrusted() else { throw ActionError.failed("Enable Wave in Accessibility settings first.") }
        if await verified(on) { return }

        // pmset mutation requires root on Apple Silicon. Use System Settings UI scripting.
        let desired = on ? "Always" : "Never"
        let script = """
        tell application "System Settings" to activate
        open location "x-apple.systempreferences:com.apple.Battery-Settings.extension"
        delay 0.5
        tell application "System Events"
            tell process "System Settings"
                try
                    set p to first pop up button of group 1 of scroll area 1 of group 1 of group 3 of splitter group 1 of group 1 of window 1 whose name is "Low Power Mode"
                    if not (exists menu 1 of p) then
                        click p
                        delay 0.3
                    end if
                    click menu item "\(desired)" of menu 1 of p
                end try
            end tell
        end tell
        """

        _ = try? await MacCommand.appleScript(script)

        // Verify state up to 3 seconds
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(200))
            if await verified(on) { return }
        }

        // Fallback: Accessibility API traversal
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences") +
                   NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.SystemSettings")
        if let app = apps.first {
            app.activate(options: [.activateIgnoringOtherApps])
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.3)
            let items = AX.descendants(root, limit: 1200)
            for item in items {
                let role = AX.string(item, kAXRoleAttribute)
                let label = [
                    AX.string(item, kAXTitleAttribute),
                    AX.string(item, kAXDescriptionAttribute),
                    AX.string(item, kAXHelpAttribute)
                ].joined(separator: " ").lowercased()

                if (role == kAXCheckBoxRole || role == "AXSwitch"), label.contains("low power") {
                    let current = (AX.value(item, kAXValueAttribute) as? NSNumber)?.boolValue
                    if current != on {
                        _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    }
                }

                if role == kAXPopUpButtonRole && label.contains("low power") {
                    _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    try await Task.sleep(for: .milliseconds(200))
                    let choices = (AX.descendants(item) + AX.descendants(root)).filter { AX.string($0, kAXRoleAttribute) == kAXMenuItemRole }
                    let targetChoice = choices.first { choice in
                        let t = AX.string(choice, kAXTitleAttribute).lowercased()
                        return on ? (t.contains("always") || t.contains("low power")) : (t.contains("never") || t.contains("automatic"))
                    }
                    if let choice = targetChoice {
                        _ = AXUIElementPerformAction(choice, kAXPressAction as CFString)
                    } else {
                        Keyboard.press(53)
                    }
                }
            }
        }

        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(200))
            if await verified(on) { return }
        }

        throw ActionError.failed("Couldn't verify Low Power Mode in Battery settings. Check Wave's Accessibility permission.")
    }

    private static func verified(_ on: Bool) async -> Bool {
        guard let result = try? await MacCommand.run(.power, ["-g", "custom"]), result.status == 0 else { return false }
        let values = String(decoding: result.output, as: UTF8.self).split(separator: "\n").compactMap { line -> Int? in
            let pieces = line.split(whereSeparator: \.isWhitespace)
            guard pieces.first == "lowpowermode", let last = pieces.last else { return nil }
            return Int(last)
        }
        return !values.isEmpty && (on ? values.contains(1) : values.allSatisfy { $0 == 0 })
    }
}

@MainActor
enum Keyboard {
    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(25_000) // 25ms hold
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    static func type(_ text: String) async throws {
        func postSingleChar(_ character: Character) {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 0, keyDown: down)
                units.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
                event?.post(tap: .cghidEventTap)
            }
        }
        for character in text {
            try Task.checkCancellation()
            postSingleChar(character)
            // Visibly human-readable typing speed: ~35ms per keystroke (~28 characters/second)
            try await Task.sleep(for: .milliseconds(35))
        }
    }
}
