import AppKit
import ApplicationServices

@MainActor
enum AccessibilityElementFinder {
    private static var hasPromptedForPermission = false

    /// Verifies Accessibility permission, prompting the user with an informative dialog on first failure.
    static func verifyPermission() throws {
        if AXIsProcessTrusted() { return }

        if !hasPromptedForPermission {
            hasPromptedForPermission = true
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "Wave needs Accessibility permission to locate UI elements, guide the cursor, and click on your behalf. Please enable Wave in System Settings > Privacy & Security > Accessibility."
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        throw ActionError.failed("Accessibility permission is required for Wave to interact with apps.")
    }

    /// Finds a UI element inside the specified app matching `label` and returns its on-screen center in CoreGraphics points.
    /// Returns nil if not found (never blind-clicks guessed coordinates).
    static func findCenter(app appName: String, label targetLabel: String) async throws -> CGPoint? {
        try verifyPermission()

        guard let targetApp = findOrLaunchApp(appName) else {
            return nil
        }

        // Activate target application so its window is brought front and UI elements become accessible
        targetApp.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(for: .milliseconds(200))

        let appRef = AXUIElementCreateApplication(targetApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appRef, 0.25)

        // Prioritize focused window, then main window, then any standard window
        var windowsToSearch: [AXUIElement] = []
        if let focused = AX.element(AX.value(appRef, kAXFocusedWindowAttribute)) {
            windowsToSearch.append(focused)
        }
        if let main = AX.element(AX.value(appRef, kAXMainWindowAttribute)), !windowsToSearch.contains(where: { CFEqual($0, main) }) {
            windowsToSearch.append(main)
        }
        if let allWindows = AX.value(appRef, kAXWindowsAttribute) as? [AXUIElement] {
            for win in allWindows {
                if !windowsToSearch.contains(where: { CFEqual($0, win) }) {
                    windowsToSearch.append(win)
                }
            }
        }

        if windowsToSearch.isEmpty {
            windowsToSearch.append(appRef)
        }

        let cleanTarget = targetLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isAddressBarQuery = cleanTarget.contains("address") || cleanTarget.contains("url") || cleanTarget == "address bar"

        for root in windowsToSearch {
            if let hit = searchElement(root: root, target: cleanTarget, isAddressBar: isAddressBarQuery) {
                return hit
            }
        }

        return nil
    }

    private static func searchElement(root: AXUIElement, target: String, isAddressBar: Bool) -> CGPoint? {
        var queue = [root]
        var inspected = 0
        let maxNodes = 600

        var bestCandidate: (element: AXUIElement, score: Int, frame: CGRect)?

        while !queue.isEmpty && inspected < maxNodes {
            let current = queue.removeFirst()
            inspected += 1

            let children = AX.children(current)
            queue.append(contentsOf: children)

            guard let frame = AX.frame(current), frame.width > 3, frame.height > 3 else {
                continue
            }

            // Must be on a visible screen
            if frame.maxX <= 0 || frame.maxY <= 0 { continue }

            let title = AX.string(current, kAXTitleAttribute).lowercased()
            let desc = AX.string(current, kAXDescriptionAttribute).lowercased()
            let help = AX.string(current, kAXHelpAttribute).lowercased()
            let role = AX.string(current, kAXRoleAttribute)
            let roleDesc = AX.string(current, kAXRoleDescriptionAttribute).lowercased()
            let val = (AX.value(current, kAXValueAttribute) as? String)?.lowercased() ?? ""
            let placeholder = (AX.value(current, kAXPlaceholderValueAttribute) as? String)?.lowercased() ?? ""

            var score = 0

            // 1. Exact match on title or description
            if title == target || desc == target {
                score += 100
            } else if title.contains(target) || desc.contains(target) {
                score += 60
            } else if placeholder.contains(target) || help.contains(target) || roleDesc.contains(target) {
                score += 40
            }

            // 2. Browser address bar special handling (Chrome / Safari)
            if isAddressBar {
                let isTextOrCombo = (role == "AXTextField" || role == "AXComboBox" || role == "AXSearchField")
                if desc.contains("address") || title.contains("address") || placeholder.contains("search or enter") {
                    score += 90
                } else if isTextOrCombo && (desc.contains("search") || title.contains("search")) {
                    score += 70
                } else if isTextOrCombo && frame.width > 200 && frame.height < 60 && frame.minY < 200 {
                    // Typical URL bar geometry in browser windows
                    score += 50
                }
            }

            // 3. Partial keyword matching
            let words = target.split(separator: " ").map(String.init)
            if words.count > 1 {
                let matchedWords = words.filter { word in
                    title.contains(word) || desc.contains(word) || placeholder.contains(word) || val.contains(word)
                }
                score += (matchedWords.count * 15)
            }

            if score > 0 {
                if let currentBest = bestCandidate {
                    if score > currentBest.score {
                        bestCandidate = (current, score, frame)
                    }
                } else {
                    bestCandidate = (current, score, frame)
                }
            }
        }

        if let best = bestCandidate, best.score >= 30 {
            return CGPoint(x: best.frame.midX, y: best.frame.midY)
        }
        return nil
    }

    private static func findOrLaunchApp(_ name: String) -> NSRunningApplication? {
        let clean = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return nil }

        // Check running applications
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == clean ||
            $0.localizedName?.lowercased().contains(clean) == true ||
            $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == clean
        }) {
            return app
        }

        // Try standard AppLookup
        if let url = AppLookup.url(clean) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let semaphore = DispatchSemaphore(value: 0)
            var launchedApp: NSRunningApplication?

            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
                launchedApp = app
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2.0)
            return launchedApp
        }

        return nil
    }
}
