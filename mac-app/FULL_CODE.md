# Wave — complete app code

Place these four Swift files in the Wave app target. The Xcode project and pinned SPM dependency are supplied.

## Wave/WaveApp.swift

```swift
import SwiftUI

@main
struct WaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Wave", systemImage: "hand.wave.fill") {
            WaveMenu(model: delegate.model)
        }
    }
}

private struct WaveMenu: View {
    @ObservedObject var model: WaveModel

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
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = WaveModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
```

## Wave/WaveModel.swift

```swift
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

    func setEnabled(_ enabled: Bool) {
        gestures.setEnabled(enabled)
        enabledAt = ProcessInfo.processInfo.systemUptime
        updateMode()
        guard enabled else {
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
        // Core Graphics uses top-left coordinates in display points, not Retina pixels.
        let result = gestures.process(points, time: time, screen: CGDisplayBounds(CGMainDisplayID()))
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
        camera.setRunning(false)
    }
}
```

## Wave/HandCamera.swift

```swift
import AVFoundation
import MediaPipeTasksVision
import MediaPipeTasksVisionHandLandmarker

/// Camera and inference are confined to one serial queue. Late frames are dropped.
final class HandCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: (([CGPoint], Double) -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "Wave.camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    private var landmarker: HandLandmarker?
    private var configured = false
    private var lastTimestamp = 0
    private var running = false
    private var runtimeObserver: NSObjectProtocol?

    override init() {
        super.init()
        runtimeObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError?(error?.localizedDescription ?? "Camera session failed. Toggle On to retry.")
        }
    }

    deinit {
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
    }

    func setRunning(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if enabled {
                    if !configured { try configure() }
                    running = true
                    if !session.isRunning { session.startRunning() }
                } else {
                    running = false
                    if session.isRunning { session.stopRunning() }
                }
            } catch {
                running = false
                onError?(error.localizedDescription)
            }
        }
    }

    private func configure() throws {
        let options = try HandLandmarkerModel.makeOptions(runningMode: .video, numberOfHands: 1)
        landmarker = try HandLandmarker(options: options)
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CameraError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input) else { throw CameraError.configuration }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraError.configuration
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false // Mirrored exactly once when mapping the cursor.
        }
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running, let landmarker,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = ProcessInfo.processInfo.systemUptime
        let timestamp = max(lastTimestamp + 1, Int(time * 1_000))
        lastTimestamp = timestamp
        do {
            let image = try MPImage(pixelBuffer: buffer)
            let result = try landmarker.detect(videoFrame: image, timestampInMilliseconds: timestamp)
            let points = result.landmarks.first?.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) } ?? []
            onFrame?(points, time)
        } catch {
            running = false
            session.stopRunning()
            onError?(error.localizedDescription)
        }
    }
}

private enum CameraError: LocalizedError {
    case unavailable, configuration
    var errorDescription: String? {
        switch self {
        case .unavailable: return "No camera found. Connect a camera and toggle On to retry."
        case .configuration: return "Cannot configure the camera. Toggle On to retry."
        }
    }
}
```

## Wave/GestureEngine.swift

```swift
import Foundation
import CoreGraphics

/// Pure gesture state, independent of camera, permissions, and event posting.
struct GestureEngine {
    enum Mode { case active, paused, off }
    private(set) var mode: Mode = .active
    private var palmSince: Double?
    private var missingSince: Double?
    private var canResume = false
    private var pinchArmed = false
    private var lastClick = -Double.infinity
    private var smoothed: CGPoint?
    private var lastFrame: Double?

    mutating func setEnabled(_ enabled: Bool) {
        self = GestureEngine()
        mode = enabled ? .active : .off
    }

    mutating func process(_ points: [CGPoint], time: Double, screen: CGRect) -> (point: CGPoint?, click: Bool) {
        guard mode != .off else { return (nil, false) }
        if let lastFrame, time - lastFrame > 0.3 {
            palmSince = nil
            pinchArmed = false
            smoothed = nil
        }
        lastFrame = time
        guard points.count == 21, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            palmSince = nil
            smoothed = nil
            pinchArmed = false
            if missingSince == nil { missingSince = time }
            if time - (missingSince ?? time) >= 0.5 { canResume = true }
            return (nil, false)
        }
        missingSince = nil
        if mode == .paused {
            guard canResume else { return (nil, false) }
            mode = .active
            canResume = false
        }
        // Coordinates are measured in image-pixel proportions (640:480).
        func distance(_ a: Int, _ b: Int) -> CGFloat {
            hypot((points[a].x - points[b].x) * 4 / 3, points[a].y - points[b].y)
        }
        let scale = max(distance(0, 9), 0.02)
        let pinch = distance(4, 8) / scale
        let openPalm = [(8, 6), (12, 10), (16, 14), (20, 18)].allSatisfy {
            distance($0.0, 0) > distance($0.1, 0) * 1.18
        } && distance(4, 17) > distance(3, 17) * 1.1 && pinch > 0.65
        if openPalm {
            if palmSince == nil { palmSince = time }
            if time - (palmSince ?? time) >= 1 {
                mode = .paused
                canResume = false
                pinchArmed = false
                smoothed = nil
                return (nil, false)
            }
        } else {
            palmSince = nil
        }
        let target = CGPoint(
            x: screen.minX + min(max(1 - points[8].x, 0), 1) * max(screen.width - 1, 0),
            y: screen.minY + min(max(points[8].y, 0), 1) * max(screen.height - 1, 0)
        )
        if let previous = smoothed {
            smoothed = CGPoint(x: previous.x + 0.25 * (target.x - previous.x),
                               y: previous.y + 0.25 * (target.y - previous.y))
        } else { smoothed = target }
        // Require an observed release, including after hand loss or a mode change.
        if pinch > 0.45 { pinchArmed = true }
        var click = false
        if pinch < 0.25 && pinchArmed {
            click = time - lastClick >= 0.3
            pinchArmed = false
            if click { lastClick = time }
        }
        return (smoothed, click)
    }
}
```

## Exact Swift Package Manager setup

The project already contains this dependency and its resolved revision. For a fresh Xcode project:

1. Choose **File > Add Package Dependencies…** and enter `https://github.com/vcamapp/mediapipe.git`.
2. Choose **Commit** as the dependency rule and enter `944568ca9714d5be95b62f6a610582470ba4bae5`.
3. Click **Add Package**; add **MediaPipeTasksVisionHandLandmarker** to the **Wave** target. It includes the framework and `hand_landmarker.task`; no separate model download or additional product is needed.
4. Set the macOS deployment target to **14.0**, Architectures to **arm64**, Swift language version to **5**, and Default Actor Isolation to **nonisolated**. Use Xcode 26.x or newer.
5. Disable **App Sandbox**, retain **Hardened Runtime**, and enable its **Camera** resource access. Add the Info properties below.

This is the **unofficial VCam distribution**, not a Google-supported macOS Swift SDK. It builds native macOS MediaPipe from upstream sources and provides a checksum-verified XCFramework through SPM. Google's documented Apple integration is for iOS via CocoaPods. Sources: https://github.com/vcamapp/mediapipe and https://ai.google.dev/edge/mediapipe/solutions/vision/hand_landmarker/ios .

## Info.plist entries

Xcode generates Info.plist in this project. The following values are configured in target build settings; do not also add an Info.plist to the synchronized source folder.

```xml
<key>LSUIElement</key>
<true/>
<key>NSCameraUsageDescription</key>
<string>Wave uses the camera to track your hand gestures. Frames are processed on-device and never stored or sent anywhere.</string>
```

Corresponding build settings: `INFOPLIST_KEY_LSUIElement = YES` and `INFOPLIST_KEY_NSCameraUsageDescription =` the string above. `ENABLE_RESOURCE_ACCESS_CAMERA = YES` supplies the hardened-runtime camera entitlement when signing. Sandbox is disabled because this prototype posts system-wide input events.

## Run and permissions — five lines

1. Open `~/wave-mac/Wave.xcodeproj` in Xcode 26.x on an Apple Silicon Mac; select Wave > My Mac.
2. Select your signing team if needed, then press Command-R; Wave appears only in the menu bar and starts On.
3. Use the launch alert to open Privacy & Security > Accessibility; enable Wave (use + to add the built Wave.app if absent).
4. Allow the camera prompt; if previously denied, enable Wave in Privacy & Security > Camera and quit/reopen it.
5. Point to move, pinch/release to click, hold an open palm for one second to pause; toggle On or remove your hand for half a second and return to resume.

## Behavior and prototype boundaries

- Controls the primary display. Uses Core Graphics display coordinates, mirrors X once, clamps to screen bounds, and lerps with a factor of 0.25.
- Uses MediaPipe HandLandmarker video mode with monotonic timestamps on the camera's serial queue. AVFoundation drops late frames, and UI processing rejects results older than 300 ms. Video mode retains tracking between frames and is used on the live camera stream.
- Pinch distances are divided by wrist-to-middle-knuckle distance. Press threshold: 0.25; release threshold: 0.45; minimum interval between clicks: 300 ms. A visible release is required before the first click and after hand loss.
- An open palm is a simple landmark-distance heuristic, with one second of continuous detection. Keep fingers extended and palm facing the camera. Lighting, occlusion, hand orientation, and camera framing affect reliability.
- Palm pause keeps the camera running so it can detect departure and reappearance. Manual Off stops the camera and can only be resumed with the menu toggle. A held pinch or a single missed frame cannot resume a pause or produce repeated clicks.
- Permission is rechecked before posting events. Camera/model errors appear in the menu and switch mode Off; toggle On to retry. No screen-recording or microphone permission is used.

## Validation

The Debug arm64 app compiled and linked with the real pinned MediaPipe XCFramework in Xcode 26.6, without Swift compiler errors or warnings. Xcode emits its standard informational App Intents metadata warning because this app has no App Intents dependency. Generated Info.plist has `LSUIElement = true`, the exact camera description, and minimum system version 14.0.

Gesture checks pass for mirrored mapping, smoothing, pinch release/debounce, hand loss, palm timing, reappearance, and manual Off. Run them from the installed project root:

```sh
xcrun swiftc Wave/GestureEngine.swift Tests/main.swift -o /tmp/wave-gesture-tests
/tmp/wave-gesture-tests
```

Real camera accuracy, permission UI, and physical cursor/click behavior require the five-line hands-on run above; they have not been verified by automated input on this Mac.
