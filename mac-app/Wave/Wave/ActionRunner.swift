import AppKit
import ApplicationServices
import Combine

@MainActor
final class ActionRunner: ObservableObject {
    @Published private(set) var status = "Actions ready"
    @Published private(set) var log: [String] = []
    @Published private(set) var running = false
    @Published private(set) var lastResult: String?
    weak var waveCursor: WaveCursorController?
    weak var buddyPill: BuddyPillController?
    private let installer = AppInstaller()

    func run(_ response: AgentReply, target: SelectedTarget?) async -> String? {
        guard !running else { return "I'm still finishing your last action." }
        running = true
        defer {
            running = false
            CursorVisibilityManager.restore()
        }
        installer.progress = { [weak self] in self?.status = $0 }
        var failures: [String] = []
        lastResult = nil
        if response.rejected > 0 {
            record("Rejected \(response.rejected) invalid action(s)")
            failures.append("The backend returned an unsupported action.")
        }

        let hasAgenticActions = response.actions.contains { action in
            switch action {
            case .clickElement, .typeText, .pressKey, .closeThis, .minimizeThis, .openThis:
                return true
            default:
                return false
            }
        }

        var cursorActive = false
        if hasAgenticActions, let waveCursor, let buddyPill {
            await waveCursor.beginSequence(ballCenterCG: buddyPill.ballCenterCG)
            cursorActive = true
        }

        for action in response.actions {
            if Task.isCancelled { record("Remaining actions cancelled"); break }
            status = action.label
            record("Running: \(action.label)")
            do {
                let result = try await execute(action, target: target)
                lastResult = result
                record("Done: \(result)")
                status = result
            } catch {
                let message = error.localizedDescription
                record("Failed: \(action.label) — \(message)")
                failures.append(message)
                status = message
            }
        }

        if cursorActive, let waveCursor, let buddyPill {
            await waveCursor.endSequence(ballCenterCG: buddyPill.ballCenterCG)
        }

        return failures.first.map { "I couldn't finish that: \($0)" }
    }

    private func record(_ line: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .standard))  \(line)", at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }

    private func execute(_ action: AgentAction, target: SelectedTarget?) async throws -> String {
        switch action {
        case .openApp(let name):
            try await open(name)
            return "Opened \(name)"

        case .closeApp(let name):
            try await close(name)
            return "Closed \(name)"

        case .lowPower(let on):
            try await LowPowerControl.set(on)
            return "Low Power Mode \(on ? "On" : "Off")"

        case .darkMode(let on):
            try await MacCommand.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
            return "Dark Mode \(on ? "On" : "Off")"

        case .volume(let level):
            try await MacCommand.appleScript("set volume output volume \(level)")
            return "Volume set to \(level)%"

        case .mute(let on):
            try await MacCommand.appleScript("set volume output muted \(on)")
            return on ? "Muted" : "Unmuted"

        case .openURL(let url):
            let browserBundles: Set<String> = [
                "com.apple.Safari",
                "com.google.Chrome",
                "company.thebrowser.Browser",
                "org.mozilla.firefox",
                "com.brave.Browser",
                "com.microsoft.edgemac"
            ]
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               let bundle = frontmost.bundleIdentifier,
               browserBundles.contains(bundle),
               let appURL = frontmost.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: nil)
                return "Opened \(url.host ?? "URL") in \(frontmost.localizedName ?? "browser")"
            }
            guard NSWorkspace.shared.open(url) else { throw ActionError.failed("Couldn't open the URL.") }
            return "Opened \(url.host ?? "URL")"

        case .minimizeFront:
            try requireAccessibility()
            Keyboard.press(46, flags: .maskCommand) // Cmd+M
            return "Minimized front window"

        case .typeText(let text):
            try requireAccessibility()
            try await Keyboard.type(text)
            return "Typed text"

        case .pressKey(let key):
            try requireAccessibility()
            let codes: [String: CGKeyCode] = [
                "escape": 53, "esc": 53,
                "enter": 36, "return": 36,
                "space": 49,
                "tab": 48,
                "delete": 51, "backspace": 51,
                "up": 126, "down": 125, "left": 123, "right": 124
            ]
            guard let code = codes[key.lowercased()] else { throw ActionError.invalidAction }
            Keyboard.press(code)
            return "Pressed \(key)"

        case .wait(let seconds):
            let ms = UInt64(max(0.0, seconds) * 1000)
            try await Task.sleep(for: .milliseconds(ms))
            return "Waited \(seconds)s"

        case .closeThis, .minimizeThis, .openThis:
            try requireAccessibility()
            guard let target else { throw ActionError.failed("Point at a window or Dock icon first.") }
            try target.validate()
            if target.context.kind == "dock_icon" {
                switch action {
                case .openThis:
                    var opened = false
                    if AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success {
                        opened = true
                    }
                    if !opened, let url = target.appURL {
                        let config = NSWorkspace.OpenConfiguration()
                        config.activates = true
                        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                        opened = true
                    } else if !opened {
                        try? await open(target.context.app)
                    }
                    return "Opened \(target.context.app)"

                case .closeThis:
                    try await close(target.context.app)
                    return "Closed \(target.context.app)"

                default:
                    throw ActionError.failed("Point at a window to minimize it.")
                }
            } else {
                switch action {
                case .closeThis:
                    NSRunningApplication(processIdentifier: target.pid)?.activate(options: [.activateIgnoringOtherApps])
                    _ = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
                    try await Task.sleep(for: .milliseconds(50))

                    var closed = false
                    if let button = AX.element(AX.value(target.element, kAXCloseButtonAttribute)) {
                        closed = (AXUIElementPerformAction(button, kAXPressAction as CFString) == .success)
                    }
                    if !closed {
                        let closeButtons = AX.children(target.element).filter {
                            AX.string($0, kAXSubroleAttribute) == kAXCloseButtonSubrole ||
                            AX.string($0, kAXRoleAttribute) == "AXCloseButton"
                        }
                        if let button = closeButtons.first {
                            closed = (AXUIElementPerformAction(button, kAXPressAction as CFString) == .success)
                        }
                    }
                    if !closed {
                        // Cmd+W fallback to close active window
                        Keyboard.press(13, flags: .maskCommand)
                    }
                    return "Closed \(target.context.app)"

                case .minimizeThis:
                    var minimized = (AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success)
                    if !minimized {
                        if let button = AX.element(AX.value(target.element, kAXMinimizeButtonAttribute)) {
                            minimized = (AXUIElementPerformAction(button, kAXPressAction as CFString) == .success)
                        }
                    }
                    if !minimized {
                        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [.activateIgnoringOtherApps])
                        Keyboard.press(46, flags: .maskCommand)
                    }
                    return "Minimized \(target.context.app)"

                default:
                    AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    NSRunningApplication(processIdentifier: target.pid)?.activate(options: [.activateIgnoringOtherApps])
                    _ = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
                    return "Raised \(target.context.app)"
                }
            }

        case .clickElement(let app, let label):
            try requireAccessibility()
            status = "Finding \(label) in \(app)…"
            guard let center = try await AccessibilityElementFinder.findCenter(app: app, label: label) else {
                throw ActionError.failed("Couldn't find \(label) in \(app).")
            }
            if let waveCursor {
                await waveCursor.glide(to: center, duration: 0.35)
                await waveCursor.pulseClick(at: center)
            }
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: 1)
            up?.setIntegerValueField(.mouseEventClickState, value: 1)
            down?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(40))
            up?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(150))
            return "Clicked \(label) in \(app)"

        case .install(let name):
            let result = try await installer.install(name)
            return result
        }
    }

    private func requireAccessibility() throws {
        try AccessibilityElementFinder.verifyPermission()
    }

    private func open(_ name: String) async throws {
        guard let url = AppLookup.url(name) else { throw ActionError.failed("\(name) isn't installed.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func close(_ name: String) async throws {
        let bundle = AppLookup.url(name).flatMap { Bundle(url: $0)?.bundleIdentifier }
        var apps = bundle.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0) } ?? []
        if apps.isEmpty {
            apps = NSWorkspace.shared.runningApplications.filter {
                $0.localizedName?.lowercased() == name.lowercased() ||
                $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased()
            }
        }
        guard !apps.isEmpty else { return }

        // Step 1: Graceful AppleScript quit
        var appleScriptAttempted = false
        if let bundle {
            appleScriptAttempted = true
            _ = try? await MacCommand.appleScript("tell application id \(MacCommand.literal(bundle)) to quit")
        }
        if !appleScriptAttempted {
            _ = try? await MacCommand.appleScript("tell application \(MacCommand.literal(name)) to quit")
        }

        // Wait up to 1.5 seconds for graceful quit
        for _ in 0..<15 {
            if apps.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(for: .milliseconds(100))
        }

        // Step 2: Fall back to terminate()
        for app in apps where !app.isTerminated {
            _ = app.terminate()
        }

        // Wait up to 1.0 second for termination
        for _ in 0..<10 {
            if apps.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw ActionError.failed("\(name) is still open; it may need you to save a document or confirm quitting.")
    }
}

@MainActor
enum AppLookup {
    static func url(_ name: String) -> URL? {
        let search = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if search.isEmpty { return nil }

        // 1. Direct path check in standard application roots (handles Cryptexes & firmlinks)
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for root in roots {
            let direct = URL(fileURLWithPath: "\(root)/\(name).app")
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
            let directCapital = URL(fileURLWithPath: "\(root)/\(name.capitalized).app")
            if FileManager.default.fileExists(atPath: directCapital.path) { return directCapital }
        }

        // 2. System bundle lookup (e.g. Safari -> com.apple.Safari, Terminal -> com.apple.Terminal)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.\(name)") ??
                     NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.\(search.capitalized)") {
            return url
        }

        // 3. Check running applications
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == search ||
            $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == search
        }), let url = app.bundleURL {
            return url
        }

        // 4. Scan candidate files in application directories
        var candidateFiles: [URL] = []
        for root in roots {
            let rootUrl = URL(fileURLWithPath: root)
            if let files = try? FileManager.default.contentsOfDirectory(at: rootUrl, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                candidateFiles.append(contentsOf: files.filter { $0.pathExtension == "app" })
            }
        }

        // Exact match
        if let match = candidateFiles.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == search }) {
            return match
        }

        // Substring match
        if let match = candidateFiles.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased().contains(search) }) {
            return match
        }

        // 5. Fallback via LaunchServices bundle identifier
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return url
        }

        return nil
    }
}
