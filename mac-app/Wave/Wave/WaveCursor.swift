import AppKit
import SwiftUI
import Combine

// MARK: - Failsafe System Cursor Visibility Manager

@MainActor
final class CursorVisibilityManager {
    private static var isHidden = false
    private static var savedLocation: CGPoint = .zero
    private static var watchdogTask: Task<Void, Never>?
    private static var terminationObserver: Any?

    static func hide() {
        guard !isHidden else { return }

        // Remember exact physical mouse location before hiding
        savedLocation = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        CGDisplayHideCursor(kCGNullDirectDisplay)
        isHidden = true

        // Register termination observer if not yet registered
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    restore()
                }
            }
        }

        // FAILSAFE: 30-second watchdog timer guarantees system cursor is always restored
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            restore()
        }
    }

    static func restore() {
        watchdogTask?.cancel()
        watchdogTask = nil

        if isHidden {
            CGDisplayShowCursor(kCGNullDirectDisplay)
            isHidden = false
            // Restore mouse position exactly where the user had it
            CGWarpMouseCursorPosition(savedLocation)
        }
    }

    static var isSystemCursorHidden: Bool {
        isHidden
    }
}

// MARK: - Wave Cursor Overlay Panel

final class WaveCursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Wave Cursor Controller

@MainActor
final class WaveCursorController: ObservableObject {
    @Published var isVisible = false
    @Published var position: CGPoint = .zero // In CG display points (0,0 is top-left of primary screen)
    @Published var scale: CGFloat = 0.2
    @Published var opacity: Double = 0.0

    // Pulse animation state
    @Published var pulsePosition: CGPoint = .zero
    @Published var pulseScale: CGFloat = 0.3
    @Published var pulseOpacity: Double = 0.0

    private var panel: WaveCursorPanel?
    private var totalDisplayBounds: CGRect = .zero

    init() {
        setupOverlayPanel()
    }

    func setupOverlayPanel() {
        guard panel == nil else { return }

        // Compute bounding box covering all attached screens
        var unionFrame = CGRect.zero
        for screen in NSScreen.screens {
            unionFrame = unionFrame.union(screen.frame)
        }
        if unionFrame.isEmpty {
            unionFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        totalDisplayBounds = unionFrame

        let p = WaveCursorPanel(
            contentRect: unionFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.setAccessibilityElement(false)

        let rootView = WaveCursorOverlayView(controller: self, bounds: unionFrame)
        p.contentView = NSHostingView(rootView: rootView)
        self.panel = p
    }

    // MARK: - Choreography API

    func beginSequence(ballCenterCG: CGPoint) async {
        setupOverlayPanel()
        position = ballCenterCG
        scale = 0.15
        opacity = 0.0
        isVisible = true

        // Hide system cursor with failsafe protection
        CursorVisibilityManager.hide()

        panel?.orderFrontRegardless()

        // Animate OUT from the ball
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
            self.scale = 1.0
            self.opacity = 1.0
        }
        try? await Task.sleep(for: .milliseconds(120))
    }

    func glide(to targetCG: CGPoint, duration: Double = 0.35) async {
        // Ease-out smooth flight to target
        withAnimation(.timingCurve(0.20, 0.85, 0.25, 1.0, duration: duration)) {
            self.position = targetCG
        }
        try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
    }

    func pulseClick(at targetCG: CGPoint) async {
        pulsePosition = targetCG
        pulseScale = 0.35
        pulseOpacity = 0.85

        withAnimation(.easeOut(duration: 0.35)) {
            self.pulseScale = 1.75
            self.pulseOpacity = 0.0
        }
        try? await Task.sleep(for: .milliseconds(140))
    }

    func endSequence(ballCenterCG: CGPoint) async {
        // Fly back INTO the ball and fade away
        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.35)) {
            self.position = ballCenterCG
            self.scale = 0.15
            self.opacity = 0.0
        }
        try? await Task.sleep(for: .milliseconds(360))

        isVisible = false
        panel?.orderOut(nil)

        // Always restore system cursor
        CursorVisibilityManager.restore()
    }

    func emergencyRestore() {
        isVisible = false
        panel?.orderOut(nil)
        CursorVisibilityManager.restore()
    }
}

// MARK: - Sleek Pointer Shape

struct SleekPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Sleek premium arrow cursor with sharp angles, tip at (0, 0)
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 23))
        path.addLine(to: CGPoint(x: 5.8, y: 18.2))
        path.addLine(to: CGPoint(x: 11.2, y: 28.5))
        path.addLine(to: CGPoint(x: 15.0, y: 26.8))
        path.addLine(to: CGPoint(x: 9.6, y: 16.6))
        path.addLine(to: CGPoint(x: 17.5, y: 16.6))
        path.closeSubpath()
        return path
    }
}

// MARK: - Wave Cursor Overlay View

struct WaveCursorOverlayView: View {
    @ObservedObject var controller: WaveCursorController
    let bounds: CGRect

    private var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 900
    }

    // Convert CG point to local SwiftUI view coordinates inside total union bounds
    private func localPoint(from cgPoint: CGPoint) -> CGPoint {
        let cocoaY = primaryScreenHeight - cgPoint.y
        let viewX = cgPoint.x - bounds.minX
        let viewY = (bounds.maxY - cocoaY)
        return CGPoint(x: viewX, y: viewY)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if controller.isVisible {
                // 1. Calm pulse ring on click
                if controller.pulseOpacity > 0.01 {
                    let pulseCenter = localPoint(from: controller.pulsePosition)
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.55, green: 0.52, blue: 1.0),
                                    Color(red: 0.38, green: 0.36, blue: 0.95)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2.2
                        )
                        .frame(width: 32, height: 32)
                        .scaleEffect(controller.pulseScale)
                        .opacity(controller.pulseOpacity)
                        .position(pulseCenter)
                }

                // 2. Wave's Own Cursor: sleek charcoal pointer with soft indigo ring glow
                let tip = localPoint(from: controller.position)

                ZStack(alignment: .topLeading) {
                    // Soft indigo ring glow around pointer
                    SleekPointerShape()
                        .stroke(
                            Color(red: 0.42, green: 0.40, blue: 0.95).opacity(0.85),
                            lineWidth: 3.5
                        )
                        .blur(radius: 4.5)

                    // Crisp white rim outline
                    SleekPointerShape()
                        .stroke(Color.white.opacity(0.92), lineWidth: 1.2)

                    // Deep charcoal body fill
                    SleekPointerShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.18, green: 0.18, blue: 0.22),
                                    Color(red: 0.10, green: 0.10, blue: 0.13)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .frame(width: 20, height: 30)
                .shadow(color: Color.black.opacity(0.40), radius: 4, x: 1, y: 2)
                .scaleEffect(controller.scale, anchor: .topLeading)
                .opacity(controller.opacity)
                .position(x: tip.x + 10, y: tip.y + 15) // Offset so tip (0,0) is at exact point
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}
