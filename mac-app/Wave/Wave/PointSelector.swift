import AppKit
import Combine
import QuartzCore

enum OverlayStyle {
    case blinking
    case solid
}

@MainActor
final class PointSelector: ObservableObject {
    @Published private(set) var target: SelectedTarget?
    @Published private(set) var message = "Point at a window or Dock icon"
    var onSelected: (() -> Void)?
    var canSelect: () -> Bool = { true }
    weak var buddyPill: BuddyPillController?

    private let overlay = TargetOverlay()
    private let reticle = AimReticleOverlay()
    private var hoverCandidate: SelectedTarget?
    private var hoverSince = 0.0
    private var lastHitTest = 0.0
    private var smoothed: CGPoint?
    private var palmSince: Double?
    private var dismissedUntil = 0.0

    func handle(_ p: [CGPoint], time: Double) {
        guard p.count == 21 else {
            // Hand lowered or out of camera frame:
            // Hide the aim reticle and any uncommitted hover preview.
            // If a target is already confirmed (target != nil), KEEP IT ON!
            reticle.hide()
            if target == nil {
                if hoverCandidate != nil || smoothed != nil {
                    dismiss()
                }
            } else {
                hoverCandidate = nil
                smoothed = nil
            }
            return
        }

        func distance(_ a: Int, _ b: Int) -> CGFloat {
            hypot((p[a].x - p[b].x) * 4 / 3, p[a].y - p[b].y)
        }

        // 1. Open palm gesture: dismiss immediately
        func extended(_ tip: Int, _ joint: Int) -> Bool {
            distance(tip, 0) > distance(joint, 0) * 1.08
        }
        let palm = extended(8, 6) && extended(12, 10) && extended(16, 14) && extended(20, 18)
        if palm {
            if palmSince == nil { palmSince = time }
            if time - (palmSince ?? time) > 0.25 {
                dismiss()
                dismissedUntil = time + 0.6
            }
            return
        }
        palmSince = nil

        // 2. Flexible, robust pointing gesture:
        // Measure finger length along the finger itself (base knuckle to tip)
        let indexLen = distance(8, 5)
        let middleLen = distance(12, 9)
        let ringLen = distance(16, 13)
        let isPointing = indexLen > 0.09 && (indexLen > middleLen * 1.12 || indexLen > ringLen * 1.15)

        guard isPointing else {
            // Hand is present but fingers are relaxed / not pointing: clear reticle and preview
            if hoverCandidate != nil && target == nil {
                dismiss()
            } else if target == nil {
                reticle.hide()
            }
            return
        }

        guard time > dismissedUntil, canSelect() else { return }

        // 3. Ergonomic Hand Calibration:
        // Map natural comfortable hand movement box to full screen bounds:
        // X in [0.15, 0.85], Y in [0.16, 0.70]
        let rawHandX = min(max(1 - p[8].x, 0), 1)
        let rawHandY = min(max(p[8].y, 0), 1)

        let mappedX = min(max((rawHandX - 0.15) / 0.70, 0), 1)
        let mappedY = min(max((rawHandY - 0.16) / 0.54, 0), 1)

        // Smoothstep curve: fine precision in center, effortless reach to the Dock and screen edges
        let curvedX = mappedX * mappedX * (3.0 - 2.0 * mappedX)
        let curvedY = mappedY * mappedY * (3.0 - 2.0 * mappedY)

        // Pointing tilt vector (from base knuckle p[5] to fingertip p[8])
        let dirX = (1 - p[8].x) - (1 - p[5].x)
        let dirY = p[8].y - p[5].y

        let (displayBounds, _) = PointSelector.globalDisplayBounds()
        let targetX = displayBounds.minX + curvedX * displayBounds.width + dirX * 60
        let targetY = displayBounds.minY + curvedY * displayBounds.height + dirY * 60

        let point = CGPoint(
            x: min(max(targetX, displayBounds.minX), displayBounds.maxX - 1),
            y: min(max(targetY, displayBounds.minY), displayBounds.maxY - 1)
        )

        // Dynamic velocity-based smoothing:
        // Snappy when moving across the screen (0.60), smooth when aiming (0.28)
        if let prev = smoothed {
            let dist = hypot(point.x - prev.x, point.y - prev.y)
            let factor = min(max(0.28 + (dist / 400.0) * 0.35, 0.28), 0.65)
            smoothed = CGPoint(
                x: prev.x + factor * (point.x - prev.x),
                y: prev.y + factor * (point.y - prev.y)
            )
        } else {
            smoothed = point
        }

        guard let smoothed else { return }

        // 4. Hit-test against Accessibility elements
        let hit: SelectedTarget?
        if time - lastHitTest > 0.06 {
            lastHitTest = time
            hit = TargetFinder.at(smoothed)
        } else {
            hit = hoverCandidate
        }

        reticle.show(at: smoothed, isHoveringTarget: (hit != nil))

        guard let hit else {
            // Pointing at empty space: if not locked, clear hover preview
            if target == nil {
                hoverCandidate = nil
                overlay.hide()
                buddyPill?.updateHighlightTarget(rect: nil, app: nil)
                message = "Point at a window or Dock icon"
            }
            return
        }

        if let frame = AX.frame(hit.element) {
            buddyPill?.updateHighlightTarget(rect: frame, app: hit.context.app)
        }

        let isSameCandidate = hoverCandidate.map {
            CFEqual($0.element, hit.element) || ($0.pid == hit.pid && $0.context.app == hit.context.app)
        } ?? false

        let isSameAsTarget = target.map {
            CFEqual($0.element, hit.element) || ($0.pid == hit.pid && $0.context.app == hit.context.app)
        } ?? false

        if !isSameCandidate {
            // Aiming moved to a DIFFERENT target (instant response as user sweeps over Dock or windows)
            hoverCandidate = hit
            hoverSince = time

            if target == nil {
                message = "Pointing at \(hit.context.app) — hold to select"
                if let frame = AX.frame(hit.element) {
                    overlay.show(frame, label: hit.context.app, style: .blinking)
                }
            }
        } else {
            // Still aiming at the same target
            if let currentTarget = target {
                if isSameAsTarget {
                    if let frame = AX.frame(currentTarget.element) {
                        overlay.show(frame, label: currentTarget.context.app, style: .solid)
                    } else {
                        dismiss()
                    }
                } else {
                    // Was locked on target A, but steadily held pointing at target B for >= 0.5s: switch!
                    if time - hoverSince >= 0.50 {
                        target = hit
                        message = "\(hit.context.app): what do you want to do?"
                        if let frame = AX.frame(hit.element) {
                            overlay.show(frame, label: hit.context.app, style: .solid)
                        }
                        onSelected?()
                    }
                }
            } else {
                // In preview stage: require 1.1s deliberate dwell before locking in and speaking
                if time - hoverSince >= 1.10 {
                    // Selection confirmed!
                    target = hit
                    message = "\(hit.context.app): what do you want to do?"
                    if let frame = AX.frame(hit.element) {
                        overlay.show(frame, label: hit.context.app, style: .solid)
                    }
                    onSelected?()
                } else {
                    if let frame = AX.frame(hit.element) {
                        overlay.show(frame, label: hit.context.app, style: .blinking)
                    }
                }
            }
        }
    }

    func dismiss() {
        target = nil
        hoverCandidate = nil
        smoothed = nil
        reticle.hide()
        overlay.hide()
        buddyPill?.updateHighlightTarget(rect: nil, app: nil)
        message = "Point at a window or Dock icon"
    }

    static func globalDisplayBounds() -> (bounds: CGRect, primaryHeight: CGFloat) {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var rect = CGRect.null
        if count > 0 {
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &displays, &count)
            for d in displays {
                let b = CGDisplayBounds(d)
                rect = rect.isNull ? b : rect.union(b)
            }
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 982
        return (rect.isNull ? CGDisplayBounds(CGMainDisplayID()) : rect, primaryHeight)
    }
}

// MARK: - Floating Wave Aim Reticle

@MainActor
private final class AimReticleOverlay {
    private let panel: NSPanel
    private let reticleView = AimReticleView()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 28, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = reticleView
        panel.setAccessibilityElement(false)
    }

    func show(at point: CGPoint, isHoveringTarget: Bool) {
        guard let primaryScreen = NSScreen.screens.first else { return }
        let primaryHeight = primaryScreen.frame.height
        let cocoaY = primaryHeight - point.y

        panel.setFrame(
            NSRect(x: point.x - 14, y: cocoaY - 14, width: 28, height: 28),
            display: true
        )
        if reticleView.isHovering != isHoveringTarget {
            reticleView.isHovering = isHoveringTarget
            reticleView.needsDisplay = true
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class AimReticleView: NSView {
    var isHovering = false

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // Outer halo ring
        let ringColor = isHovering ?
            NSColor(calibratedRed: 0.10, green: 0.85, blue: 1.0, alpha: 0.95) :
            NSColor(calibratedRed: 0.30, green: 0.75, blue: 1.0, alpha: 0.65)
        ringColor.setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
        ring.lineWidth = isHovering ? 2.5 : 1.8
        ring.stroke()

        // Inner glowing core dot
        let coreColor = isHovering ?
            NSColor.white :
            NSColor(calibratedRed: 0.20, green: 0.85, blue: 1.0, alpha: 0.95)
        coreColor.setFill()
        let core = NSBezierPath(ovalIn: NSRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        core.fill()
    }
}

// MARK: - Highlight Overlay Window & Border View

@MainActor
private final class TargetOverlay {
    private let panel: NSPanel
    private let border = BorderView()

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = border
        panel.setAccessibilityElement(false)
    }

    func show(_ rect: CGRect, label: String, style: OverlayStyle) {
        guard let primaryScreen = NSScreen.screens.first else { return }
        let primaryHeight = primaryScreen.frame.height

        // Convert CG coordinates to Cocoa screen coordinates
        let cocoaY = primaryHeight - rect.origin.y - rect.size.height
        let frame = CGRect(
            x: rect.origin.x - 4,
            y: cocoaY - 4,
            width: rect.width + 8,
            height: rect.height + 8
        )
        panel.setFrame(frame, display: true)
        border.label = label
        border.style = style
        border.needsDisplay = true
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class BorderView: NSView {
    var label = ""
    var style: OverlayStyle = .blinking {
        didSet {
            if oldValue != style {
                updateStyle()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateStyle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        updateStyle()
    }

    func updateStyle() {
        layer?.removeAllAnimations()
        switch style {
        case .blinking:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.20
            pulse.toValue = 1.00
            pulse.duration = 0.32
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulse, forKey: "pulse")
        case .solid:
            layer?.opacity = 1.0
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .blinking:
            // Electric Cyan pulsing preview border
            let cyan = NSColor(calibratedRed: 0.05, green: 0.78, blue: 1.0, alpha: 0.95)
            cyan.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
            path.lineWidth = 4
            path.stroke()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor(calibratedRed: 0.0, green: 0.60, blue: 0.90, alpha: 0.95)
            ]
            let badge = " 👉 \(label) (hold to select) " as NSString
            badge.draw(at: CGPoint(x: 12, y: max(8, bounds.height - 24)), withAttributes: attributes)

        case .solid:
            // Vibrant Gold/Orange confirmed selection border
            let orange = NSColor.systemOrange
            orange.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
            path.lineWidth = 5
            path.stroke()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.systemOrange
            ]
            let badge = " 🎯 \(label): what do you want to do? " as NSString
            badge.draw(at: CGPoint(x: 12, y: max(8, bounds.height - 28)), withAttributes: attributes)
        }
    }
}
