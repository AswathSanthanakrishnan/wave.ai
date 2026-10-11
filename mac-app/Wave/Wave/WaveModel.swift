import AppKit
import ApplicationServices
import AVFoundation
import Combine

@MainActor
final class WaveModel: ObservableObject {
    @Published private(set) var isActive = true
    @Published private(set) var modeTitle = "Gesture mode: On"
    @Published private(set) var status = "Starting camera…"
    @Published private(set) var accessibilityGranted = false
    let selector = PointSelector()
    @Published private(set) var followCursor = false
    private let camera = HandCamera()
    private var gestures = GestureEngine()
    private var permissionTimer: Timer?
    private var enabledAt = 0.0

    func start() {
        camera.onFrame = { [weak self] points, time in
            Task { @MainActor [weak self] in self?.handle(points, time: time) }
        }
        camera.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.setEnabled(false)
                self?.status = message
            }
        }
        accessibilityGranted = AXIsProcessTrusted()
        if !accessibilityGranted {
            let alert = NSAlert()
            alert.messageText = "Allow Wave to control the cursor"
            alert.informativeText = "Enable Wave in System Settings > Privacy & Security > Accessibility. Wave needs this permission to move the cursor and click. If Wave is not listed, use + to add Wave.app."
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { openAccessibility() }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = AXIsProcessTrusted()
                if self.accessibilityGranted != granted {
                    self.accessibilityGranted = granted
                    if self.gestures.mode == .active { self.gestures.setEnabled(true) }
                }
            }
        }
        setEnabled(true)
    }

    func setFollowCursor(_ follow: Bool) {
        followCursor = follow
        selector.dismiss()
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        gestures.setEnabled(enabled)
        enabledAt = ProcessInfo.processInfo.systemUptime
        updateMode()
        guard enabled else {
            selector.dismiss()
            camera.setRunning(false)
            status = "Camera off"
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            status = "Looking for a hand…"
            camera.setRunning(true)
        case .notDetermined:
            status = "Waiting for camera permission…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.gestures.mode != .off else { return }
                    if granted { self.setEnabled(true) } else { self.cameraDenied() }
                }
            }
        default: cameraDenied()
        }
    }

    private func cameraDenied() {
        setEnabled(false)
        status = "Camera permission required"
        let alert = NSAlert()
        alert.messageText = "Allow camera access for Wave"
        alert.informativeText = "Enable Wave in System Settings > Privacy & Security > Camera, then quit and reopen Wave."
        alert.addButton(withTitle: "Open Camera Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings("Privacy_Camera")
        }
    }

    private func handle(_ points: [CGPoint], time: Double) {
        guard time >= enabledAt, ProcessInfo.processInfo.systemUptime - time < 0.3,
              gestures.mode != .off else { return }
        if !followCursor {
            accessibilityGranted = AXIsProcessTrusted()
            guard accessibilityGranted else { status = "Accessibility permission required"; return }
            selector.handle(points, time: time)
            status = points.isEmpty ? "Raise a hand and point" : "Point to select"
            return
        }
        // Core Graphics uses top-left coordinates in display points, not Retina pixels.
        let result = gestures.process(points, time: time, screen: CGDisplayBounds(CGMainDisplayID()), calibrated: true)
        updateMode()
        if gestures.mode == .paused {
            status = "Paused — remove your hand, then bring it back"
            return
        }
        accessibilityGranted = AXIsProcessTrusted()
        guard accessibilityGranted else {
            status = "Accessibility permission required"
            return
        }
        status = points.isEmpty ? "Looking for a hand…" : "Tracking hand"
        guard let point = result.point else { return }

        // Drive the physical system cursor to follow the hand
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)

        if result.click {
            for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                    mouseCursorPosition: point, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: 1)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private func updateMode() {
        isActive = gestures.mode == .active
        switch gestures.mode {
        case .active: modeTitle = "Gesture mode: On"
        case .paused: modeTitle = "Gesture mode: Off (Paused)"
        case .off: modeTitle = "Gesture mode: Off"
        }
    }

    func openAccessibility() { openSettings("Privacy_Accessibility") }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        permissionTimer?.invalidate()
        selector.dismiss()
        camera.setRunning(false)
    }
}
