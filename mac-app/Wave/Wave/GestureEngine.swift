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

    mutating func process(_ points: [CGPoint], time: Double, screen: CGRect, calibrated: Bool = false) -> (point: CGPoint?, click: Bool) {
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

        let target: CGPoint
        if calibrated {
            // Ergonomic hand box calibration:
            // Maps natural comfortable hand box [0.15, 0.85] × [0.16, 0.70] to full screen
            let rawHandX = min(max(1 - points[8].x, 0), 1)
            let rawHandY = min(max(points[8].y, 0), 1)

            let mappedX = min(max((rawHandX - 0.15) / 0.70, 0), 1)
            let mappedY = min(max((rawHandY - 0.16) / 0.54, 0), 1)

            // Smoothstep curve: fine precision in center, effortless reach to Dock and screen borders
            let curvedX = mappedX * mappedX * (3.0 - 2.0 * mappedX)
            let curvedY = mappedY * mappedY * (3.0 - 2.0 * mappedY)

            // Pointing tilt vector (from base knuckle points[5] to fingertip points[8])
            let dirX = (1 - points[8].x) - (1 - points[5].x)
            let dirY = points[8].y - points[5].y

            let targetX = screen.minX + curvedX * screen.width + dirX * 45
            let targetY = screen.minY + curvedY * screen.height + dirY * 45
            target = CGPoint(
                x: min(max(targetX, screen.minX), screen.maxX - 1),
                y: min(max(targetY, screen.minY), screen.maxY - 1)
            )

            // Velocity-based adaptive smoothing: snappy during motion, stable when holding still
            if let previous = smoothed {
                let dist = hypot(target.x - previous.x, target.y - previous.y)
                let factor = min(max(0.28 + (dist / 350.0) * 0.32, 0.28), 0.65)
                smoothed = CGPoint(x: previous.x + factor * (target.x - previous.x),
                                   y: previous.y + factor * (target.y - previous.y))
            } else {
                smoothed = target
            }
        } else {
            target = CGPoint(
                x: screen.minX + min(max(1 - points[8].x, 0), 1) * max(screen.width - 1, 0),
                y: screen.minY + min(max(points[8].y, 0), 1) * max(screen.height - 1, 0)
            )
            if let previous = smoothed {
                smoothed = CGPoint(x: previous.x + 0.25 * (target.x - previous.x),
                                   y: previous.y + 0.25 * (target.y - previous.y))
            } else { smoothed = target }
        }

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
