import AppKit
import SwiftUI
import Combine

// MARK: - Buddy Pill (Living Ball) State

enum BuddyPillState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case done
}

// MARK: - Ball Color Themes

enum BallColorTheme: String, CaseIterable, Identifiable {
    case sapphire = "Midnight Sapphire"
    case violet = "Cosmic Violet"
    case teal = "Cyber Teal"
    case pearl = "Frosted Pearl"
    case charcoal = "Deep Charcoal"

    var id: String { rawValue }
}

// MARK: - Floating Non-Activating NSPanel with Native Dragging (Zero Ghost Glitch)

final class BuddyPillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onClick: (() -> Void)?

    private var dragStartMouse: CGPoint = .zero
    private var dragStartOrigin: CGPoint = .zero
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = frame.origin
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let currentMouse = NSEvent.mouseLocation
        let dx = currentMouse.x - dragStartMouse.x
        let dy = currentMouse.y - dragStartMouse.y

        if abs(dx) > 2 || abs(dy) > 2 {
            isDragging = true
        }
        guard isDragging else { return }

        let screenFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var newX = dragStartOrigin.x + dx
        var newY = dragStartOrigin.y + dy

        // Clamp to visible screen bounds
        newX = max(screenFrame.minX, min(newX, screenFrame.maxX - frame.width))
        newY = max(screenFrame.minY, min(newY, screenFrame.maxY - frame.height))

        let newOrigin = CGPoint(x: newX, y: newY)
        setFrameOrigin(newOrigin)
        onDragMoved?(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            onDragEnded?(frame.origin)
        } else {
            onClick?()
        }
        isDragging = false
    }
}

// MARK: - Controller

@MainActor
final class BuddyPillController: ObservableObject {
    // Ball is always on: visible whenever the app runs
    @Published var enabled: Bool = true
    @Published private(set) var state: BuddyPillState = .idle
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var eyeOffset: CGSize = .zero
    @Published private(set) var isBlinking: Bool = false
    @Published private(set) var isWakePulsing: Bool = false
    @Published var theme: BallColorTheme = {
        if let raw = UserDefaults.standard.string(forKey: "buddy_pill_theme"),
           let saved = BallColorTheme(rawValue: raw) {
            return saved
        }
        return .sapphire
    }()

    /// Ball center in CoreGraphics screen coordinates (0,0 at top-left of primary screen)
    var ballCenterCG: CGPoint {
        guard let panel else {
            let primary = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            return CGPoint(x: primary.maxX - 48, y: primary.midY)
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
        return CGPoint(x: panel.frame.midX, y: primaryHeight - panel.frame.midY)
    }

    func setTheme(_ newTheme: BallColorTheme) {
        theme = newTheme
        UserDefaults.standard.set(newTheme.rawValue, forKey: "buddy_pill_theme")
    }

    private var panel: BuddyPillPanel?
    private var cancellables = Set<AnyCancellable>()
    private weak var voice: VoiceModel?
    private weak var actions: ActionRunner?
    private var isDoneActive = false
    private var doneTask: Task<Void, Never>?
    private var blinkTask: Task<Void, Never>?
    private var eyeTrackingTimer: Timer?

    // Positioning
    private(set) var homePosition: CGPoint = .zero
    private var isParkedAtHighlight = false
    private var focusPoint: CGPoint? // Cocoa coordinates

    func start(voice: VoiceModel, actions: ActionRunner) {
        self.voice = voice
        self.actions = actions
        setupPanel()
        setupBindings()
        startEyeTrackingLoop()
        startBlinkLoop()
    }

    weak var chatController: WaveChatController?

    func handleBallHover(_ hovered: Bool) {
        guard let panel else { return }
        chatController?.handleBallHover(hovered, ballFrame: panel.frame)
    }

    func setEnabled(_ on: Bool) {
        // Ball is always visible whenever the app runs
        enabled = true
        panel?.orderFrontRegardless()
    }

    // MARK: - Highlight Following

    func updateHighlightTarget(rect: CGRect?, app: String?) {
        guard let panel else { return }

        if let rect {
            isParkedAtHighlight = true
            // Convert CG screen coordinates (top-left) to Cocoa screen coordinates (bottom-left)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 982
            let cocoaRect = CGRect(
                x: rect.origin.x,
                y: primaryHeight - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            )
            focusPoint = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)

            let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let currentSize = panel.frame.size

            // Park offset to the right if there's room, otherwise to the left
            var parkX = cocoaRect.maxX + 18
            var parkY = cocoaRect.midY - currentSize.height / 2

            if parkX + currentSize.width + 10 > screen.maxX {
                parkX = cocoaRect.minX - currentSize.width - 18
            }
            if parkX < screen.minX {
                parkX = min(max(cocoaRect.maxX - currentSize.width, screen.minX + 10), screen.maxX - currentSize.width - 10)
            }
            parkX = max(screen.minX + 8, min(parkX, screen.maxX - currentSize.width - 8))
            parkY = max(screen.minY + 8, min(parkY, screen.maxY - currentSize.height - 8))

            let targetOrigin = CGPoint(x: parkX, y: parkY)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.44
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrameOrigin(targetOrigin)
            }
        } else {
            if isParkedAtHighlight {
                isParkedAtHighlight = false
                focusPoint = nil
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.44
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrameOrigin(self.homePosition)
                }
            }
        }
    }

    // MARK: - State Management

    func triggerDone() {
        guard enabled else { return }
        isDoneActive = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            self.state = .done
        }
        updatePanelFrame(for: .done)

        doneTask?.cancel()
        doneTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            self.isDoneActive = false
            withAnimation(.spring(response: 0.38, dampingFraction: 0.70)) {
                self.updateState()
            }
            self.updatePanelFrame(for: self.state)
        }
    }

    func toggleListening() {
        voice?.toggleListening()
    }

    func pulseWakeWord() {
        guard enabled else { return }
        isWakePulsing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            self.isWakePulsing = false
        }
    }

    func resetPosition() {
        guard let panel else { return }
        let size = pillSize(for: state)
        let pos = defaultPosition(for: size)
        homePosition = pos
        panel.setFrame(CGRect(origin: pos, size: size), display: true, animate: true)
        savePosition(pos)
    }

    // MARK: - Drag & Position Persistence

    private func setupPanel() {
        guard panel == nil else { return }

        let initialSize = pillSize(for: .idle)
        let initialPos = loadSavedPosition() ?? defaultPosition(for: initialSize)
        homePosition = initialPos
        let initialRect = CGRect(origin: initialPos, size: initialSize)

        let panel = BuddyPillPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityElement(false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.onDragMoved = { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            self.chatController?.updatePosition(relativeTo: panel.frame)
        }
        panel.onDragEnded = { [weak self] newOrigin in
            self?.homePosition = newOrigin
            self?.savePosition(newOrigin)
            guard let self, let panel = self.panel else { return }
            self.chatController?.updatePosition(relativeTo: panel.frame)
        }
        panel.onClick = { [weak self] in
            self?.toggleListening()
        }

        let rootView = BuddyPillView(controller: self)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        self.panel = panel

        panel.orderFrontRegardless()
    }

    private func setupBindings() {
        guard let voice, let actions else { return }

        Publishers.CombineLatest3(
            voice.$listening,
            voice.$busy,
            voice.$isSpeaking
        )
        .combineLatest(actions.$running, voice.$audioLevel)
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.updateState()
        }
        .store(in: &cancellables)
    }

    private func updateState() {
        guard !isDoneActive else { return }
        guard let voice, let actions else { return }

        self.audioLevel = voice.audioLevel

        let newState: BuddyPillState
        if voice.listening {
            newState = .listening
        } else if voice.busy || actions.running {
            newState = .thinking
        } else if voice.isSpeaking {
            newState = .speaking
        } else {
            newState = .idle
        }

        if newState != state {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.68)) {
                self.state = newState
            }
            updatePanelFrame(for: newState)
        }
    }

    private func updatePanelFrame(for state: BuddyPillState) {
        guard let panel else { return }
        let newSize = pillSize(for: state)
        let currentFrame = panel.frame
        let newOrigin = CGPoint(
            x: currentFrame.midX - newSize.width / 2,
            y: currentFrame.midY - newSize.height / 2
        )
        panel.setFrame(CGRect(origin: newOrigin, size: newSize), display: true, animate: true)
    }

    func pillSize(for state: BuddyPillState) -> CGSize {
        switch state {
        case .idle, .listening, .thinking, .speaking:
            // 64pt diameter ball + halo padding
            return CGSize(width: 84, height: 84)
        case .done:
            // Morphs into small Done pill
            return CGSize(width: 116, height: 84)
        }
    }

    func defaultPosition(for size: CGSize) -> CGPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        return CGPoint(
            x: visible.maxX - size.width - 16,
            y: visible.midY - size.height / 2
        )
    }

    private func savePosition(_ origin: CGPoint) {
        UserDefaults.standard.set(origin.x, forKey: "buddy_pill_origin_x")
        UserDefaults.standard.set(origin.y, forKey: "buddy_pill_origin_y")
    }

    private func loadSavedPosition() -> CGPoint? {
        guard UserDefaults.standard.object(forKey: "buddy_pill_origin_x") != nil,
              UserDefaults.standard.object(forKey: "buddy_pill_origin_y") != nil else {
            return nil
        }
        let x = UserDefaults.standard.double(forKey: "buddy_pill_origin_x")
        let y = UserDefaults.standard.double(forKey: "buddy_pill_origin_y")

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let clampedX = max(visible.minX, min(CGFloat(x), visible.maxX - 64))
        let clampedY = max(visible.minY, min(CGFloat(y), visible.maxY - 64))
        return CGPoint(x: clampedX, y: clampedY)
    }

    // MARK: - Living Eyes: Glancing & Blinking

    private func startEyeTrackingLoop() {
        eyeTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateEyeGlance()
            }
        }
    }

    private func updateEyeGlance() {
        guard let panel else { return }
        let ballCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let targetFocus = focusPoint ?? NSEvent.mouseLocation

        let dx = targetFocus.x - ballCenter.x
        let dy = targetFocus.y - ballCenter.y
        let dist = hypot(dx, dy)

        let maxRangeX: CGFloat = 5.2
        let maxRangeY: CGFloat = 4.0

        let targetOffset: CGSize
        if dist > 2 {
            let norm = min(dist / 140.0, 1.0)
            targetOffset = CGSize(
                width: (dx / dist) * norm * maxRangeX,
                height: (dy / dist) * norm * maxRangeY
            )
        } else {
            targetOffset = .zero
        }

        // Smooth continuous glide: never snap!
        let lerp: CGFloat = 0.12
        let newX = eyeOffset.width + (targetOffset.width - eyeOffset.width) * lerp
        let newY = eyeOffset.height + (targetOffset.height - eyeOffset.height) * lerp
        eyeOffset = CGSize(width: newX, height: newY)
    }

    private func startBlinkLoop() {
        blinkTask?.cancel()
        blinkTask = Task { @MainActor in
            while !Task.isCancelled {
                let interval = Double.random(in: 3.0...5.0)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.10)) {
                    self.isBlinking = true
                }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.12)) {
                    self.isBlinking = false
                }
            }
        }
    }

    // MARK: - Compatibility helpers for tests

    func startDrag() {
        // Compatibility check stub
    }

    func updateDrag(translation: CGSize) {
        // Compatibility check stub
    }

    func endDrag(translation: CGSize) {
        // Compatibility check stub
    }
}

// MARK: - Living BALL Companion View

struct BuddyPillView: View {
    @ObservedObject var controller: BuddyPillController
    @Environment(\.colorScheme) private var colorScheme

    @State private var isBreathing = false
    @State private var isFloating = false
    @State private var rippleScale: CGFloat = 1.0
    @State private var rippleOpacity: Double = 0.0

    var body: some View {
        ZStack {
            if controller.state == .done {
                donePillView
            } else {
                ballCompanionView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onHover { isHovered in
            controller.handleBallHover(isHovered)
        }
        .onAppear {
            startIdleAnimations()
        }
        .onChange(of: controller.isWakePulsing) { _, isPulsing in
            if isPulsing {
                triggerRipple()
            }
        }
    }

    // MARK: - The Living Ball

    private var ballCompanionView: some View {
        ZStack {
            // Soft ripple ring when listening or acknowledging wake word
            if controller.state == .listening || controller.isWakePulsing {
                Circle()
                    .stroke(glowColor.opacity(rippleOpacity), lineWidth: 1.8)
                    .frame(width: 64, height: 64)
                    .scaleEffect(rippleScale)
            }

            // Soft ambient halo glow
            Circle()
                .fill(glowColor.opacity(glowIntensity))
                .frame(width: 68, height: 68)
                .blur(radius: 8)

            // The Ball: 64pt sphere with rich radial gradient shading
            Circle()
                .fill(ballSphereGradient)
                .frame(width: 64, height: 64)
                .overlay(ballInnerRim)
                .shadow(color: Color.black.opacity(0.38), radius: 6, x: 0, y: 3.5)

            // Two tiny arms pop out while thinking; right hand scratches top of head
            if controller.state == .thinking {
                ThinkingArmsView(theme: controller.theme)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.25, anchor: .center).combined(with: .opacity),
                            removal: .scale(scale: 0.20, anchor: .center).combined(with: .opacity)
                        )
                    )
            }

            // Expressive face: bigger blinking eyes + animated mouth gliding toward focus
            VStack(spacing: 3.2) {
                HStack(spacing: 8.5) {
                    BallEye(isBlinking: controller.isBlinking, theme: controller.theme)
                    BallEye(isBlinking: controller.isBlinking, theme: controller.theme)
                }
                BallMouth(state: controller.state, isSpeaking: controller.state == .speaking, theme: controller.theme)
            }
            .offset(x: controller.eyeOffset.width, y: -controller.eyeOffset.height)
        }
        .scaleEffect(ballScale)
        .offset(y: isFloating && controller.state == .idle ? -2.5 : 2.5)
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: isFloating)
        .onChange(of: controller.audioLevel) { _, newLevel in
            if controller.state == .listening && newLevel > 0.15 {
                triggerRipple()
            }
        }
    }

    // MARK: - Morphed "Done" Pill

    private var donePillView: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(Color(red: 0.22, green: 0.88, blue: 0.48))

            Text("Done")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.18, blue: 0.22),
                            Color(red: 0.10, green: 0.10, blue: 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)
        )
        .scaleEffect(1.04)
        .transition(.scale(scale: 0.80).combined(with: .opacity))
    }

    // MARK: - Gradients & Shading

    private var ballSphereGradient: RadialGradient {
        switch controller.theme {
        case .sapphire:
            return RadialGradient(
                colors: [
                    Color(red: 0.44, green: 0.62, blue: 0.98), // Luminous sky-sapphire highlight
                    Color(red: 0.16, green: 0.26, blue: 0.60), // Rich royal sapphire mid
                    Color(red: 0.07, green: 0.09, blue: 0.26)  // Midnight navy rim
                ],
                center: UnitPoint(x: 0.36, y: 0.32),
                startRadius: 2,
                endRadius: 36
            )
        case .violet:
            return RadialGradient(
                colors: [
                    Color(red: 0.68, green: 0.46, blue: 0.98), // Luminous amethyst highlight
                    Color(red: 0.35, green: 0.16, blue: 0.60), // Deep nebula violet
                    Color(red: 0.14, green: 0.05, blue: 0.26)  // Cosmic plum rim
                ],
                center: UnitPoint(x: 0.36, y: 0.32),
                startRadius: 2,
                endRadius: 36
            )
        case .teal:
            return RadialGradient(
                colors: [
                    Color(red: 0.36, green: 0.88, blue: 0.82), // Radiant aqua highlight
                    Color(red: 0.08, green: 0.44, blue: 0.48), // Deep oceanic teal
                    Color(red: 0.03, green: 0.18, blue: 0.22)  // Abyssal teal rim
                ],
                center: UnitPoint(x: 0.36, y: 0.32),
                startRadius: 2,
                endRadius: 36
            )
        case .pearl:
            return RadialGradient(
                colors: [
                    Color(white: 0.99),                         // Brilliant white pearl highlight
                    Color(red: 0.84, green: 0.87, blue: 0.92), // Platinum ceramic mid
                    Color(red: 0.60, green: 0.64, blue: 0.72)  // Cool slate rim
                ],
                center: UnitPoint(x: 0.36, y: 0.32),
                startRadius: 2,
                endRadius: 36
            )
        case .charcoal:
            return RadialGradient(
                colors: [
                    Color(red: 0.28, green: 0.28, blue: 0.32),
                    Color(red: 0.17, green: 0.17, blue: 0.20),
                    Color(red: 0.08, green: 0.08, blue: 0.10)
                ],
                center: UnitPoint(x: 0.36, y: 0.32),
                startRadius: 2,
                endRadius: 36
            )
        }
    }

    private var ballInnerRim: some View {
        Circle()
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(controller.theme == .pearl ? 0.40 : 0.25),
                        rimAccentColor.opacity(0.35),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    private var rimAccentColor: Color {
        switch controller.theme {
        case .sapphire: return Color(red: 0.50, green: 0.70, blue: 1.0)
        case .violet:   return Color(red: 0.75, green: 0.55, blue: 1.0)
        case .teal:     return Color(red: 0.40, green: 0.92, blue: 0.88)
        case .pearl:    return Color(red: 0.65, green: 0.78, blue: 0.95)
        case .charcoal: return Color(red: 0.38, green: 0.36, blue: 0.75)
        }
    }

    private var glowColor: Color {
        switch controller.theme {
        case .sapphire: return Color(red: 0.30, green: 0.50, blue: 0.98)
        case .violet:   return Color(red: 0.62, green: 0.35, blue: 0.95)
        case .teal:     return Color(red: 0.20, green: 0.82, blue: 0.78)
        case .pearl:    return Color(red: 0.45, green: 0.65, blue: 0.95)
        case .charcoal: return Color(red: 0.34, green: 0.32, blue: 0.82)
        }
    }

    private var glowIntensity: Double {
        switch controller.state {
        case .listening:
            return 0.45 + Double(controller.audioLevel) * 0.35
        case .speaking:
            return 0.40
        case .thinking:
            return 0.30
        case .idle:
            return 0.22
        case .done:
            return 0.15
        }
    }

    private var ballScale: CGFloat {
        switch controller.state {
        case .idle:
            return isBreathing ? 1.06 : 1.00
        case .listening:
            // Bounces directly with live mic input level
            return 1.02 + CGFloat(controller.audioLevel) * 0.14
        case .speaking:
            return isBreathing ? 1.05 : 0.98
        case .thinking:
            return 1.00
        case .done:
            return 1.08
        }
    }

    // MARK: - Animation Drivers

    private func startIdleAnimations() {
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            isBreathing = true
        }
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            isFloating = true
        }
    }

    private func triggerRipple() {
        rippleScale = 1.0
        rippleOpacity = 0.65
        withAnimation(.easeOut(duration: 0.70)) {
            rippleScale = 1.45
            rippleOpacity = 0.0
        }
    }
}

// MARK: - Big Expressive Eyes

private struct BallEye: View {
    let isBlinking: Bool
    let theme: BallColorTheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Main eye capsule: bright white for dark themes, obsidian for pearl theme
            Capsule()
                .fill(theme == .pearl ? Color(red: 0.08, green: 0.10, blue: 0.16) : Color(white: 0.98))
                .frame(width: 7.6, height: isBlinking ? 1.4 : 12.8)
                .shadow(color: Color.black.opacity(theme == .pearl ? 0.15 : 0.25), radius: 1.2, x: 0, y: 0.8)

            // Glossy catchlight gleam (hidden when blinking)
            if !isBlinking {
                Circle()
                    .fill(theme == .pearl ? Color(red: 0.25, green: 0.88, blue: 0.98) : Color.white)
                    .frame(width: 2.2, height: 2.2)
                    .offset(x: -1.2, y: 2.0)
            }
        }
    }
}

// MARK: - Animated Mouth (Calm Smile & Speech Cadence)

private struct BallMouth: View {
    let state: BuddyPillState
    let isSpeaking: Bool
    let theme: BallColorTheme
    @State private var speechCadence = false

    private var mouthColor: Color {
        theme == .pearl ? Color(red: 0.10, green: 0.12, blue: 0.18) : Color.white.opacity(0.88)
    }

    var body: some View {
        Group {
            if isSpeaking {
                // Rhythmic speaking mouth opening and closing smoothly with voice
                Capsule()
                    .fill(theme == .pearl ? Color(red: 0.22, green: 0.24, blue: 0.30) : Color(red: 0.16, green: 0.16, blue: 0.20))
                    .overlay(
                        Capsule()
                            .stroke(mouthColor, lineWidth: 1.1)
                    )
                    .frame(
                        width: speechCadence ? 6.8 : 5.4,
                        height: speechCadence ? 4.8 : 1.8
                    )
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.15).repeatForever(autoreverses: true)) {
                            speechCadence = true
                        }
                    }
                    .onDisappear {
                        speechCadence = false
                    }
            } else if state == .done {
                // Wide happy smile upon completion
                HappySmileShape()
                    .stroke(mouthColor, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    .frame(width: 8.5, height: 3.8)
            } else {
                // Small calm resting smile (idle, listening, thinking)
                CalmSmileShape()
                    .stroke(mouthColor, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                    .frame(width: 7.2, height: 2.6)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isSpeaking)
    }
}

private struct CalmSmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + 0.3))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + 0.3),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return path
    }
}

private struct HappySmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + 0.2))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + 0.2),
            control: CGPoint(x: rect.midX, y: rect.maxY + 1.0)
        )
        return path
    }
}

// MARK: - Thinking Arms View (Pops out, right hand scratches top of head)

private struct ThinkingArmsView: View {
    let theme: BallColorTheme
    @State private var scratchPhase = false

    var body: some View {
        ZStack {
            // LEFT ARM: cute little arm resting on hip/side
            leftArm

            // RIGHT ARM: reaches up and curls over to scratch top of head
            rightArm

            // Cute scratch motion accents on head
            scratchAccents
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.20).repeatForever(autoreverses: true)) {
                scratchPhase = true
            }
        }
    }

    private var armGradient: LinearGradient {
        switch theme {
        case .sapphire:
            return LinearGradient(
                colors: [Color(red: 0.22, green: 0.36, blue: 0.72), Color(red: 0.09, green: 0.14, blue: 0.35)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .violet:
            return LinearGradient(
                colors: [Color(red: 0.42, green: 0.22, blue: 0.68), Color(red: 0.16, green: 0.08, blue: 0.32)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .teal:
            return LinearGradient(
                colors: [Color(red: 0.15, green: 0.52, blue: 0.55), Color(red: 0.05, green: 0.22, blue: 0.26)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .pearl:
            return LinearGradient(
                colors: [Color(white: 0.92), Color(red: 0.70, green: 0.74, blue: 0.80)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .charcoal:
            return LinearGradient(
                colors: [Color(red: 0.26, green: 0.26, blue: 0.30), Color(red: 0.12, green: 0.12, blue: 0.15)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    private var armRimColor: Color {
        theme == .pearl ? Color.white.opacity(0.40) : Color.white.opacity(0.18)
    }

    private var leftArm: some View {
        ZStack {
            // Arm limb
            Capsule()
                .fill(armGradient)
                .frame(width: 5.5, height: 13)
                .overlay(Capsule().stroke(armRimColor, lineWidth: 0.8))
                .rotationEffect(.degrees(26))
                .offset(x: -33.5, y: 3.5)

            // Rounded mitten hand resting on hip
            Circle()
                .fill(armGradient)
                .frame(width: 6.2, height: 6.2)
                .overlay(Circle().stroke(armRimColor, lineWidth: 0.8))
                .offset(x: -31, y: 9.5)
        }
        .shadow(color: Color.black.opacity(0.32), radius: 2, x: -1, y: 1.5)
    }

    private var rightArm: some View {
        ZStack {
            // Forearm reaching up along upper-right sphere curve
            Capsule()
                .fill(armGradient)
                .frame(width: 5.5, height: 19)
                .overlay(Capsule().stroke(armRimColor, lineWidth: 0.8))
                .rotationEffect(.degrees(-36))
                .offset(x: 26, y: -16)

            // Little scratching hand/paw on crown of the head
            HStack(spacing: 1.2) {
                Capsule()
                    .fill(armGradient)
                    .frame(width: 2.2, height: 5.5)
                Capsule()
                    .fill(armGradient)
                    .frame(width: 2.4, height: 6.2)
                Capsule()
                    .fill(armGradient)
                    .frame(width: 2.2, height: 5.2)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(armRimColor, lineWidth: 0.8)
            )
            .rotationEffect(.degrees(scratchPhase ? -24 : 8))
            .offset(
                x: 13.5 + (scratchPhase ? -2.2 : 2.0),
                y: -29.5 + (scratchPhase ? -1.0 : 1.2)
            )
        }
        .shadow(color: Color.black.opacity(0.32), radius: 2, x: 1, y: 1.5)
    }

    private var scratchAccents: some View {
        HStack(spacing: 2) {
            Text("~")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(scratchColor.opacity(scratchPhase ? 0.75 : 0.20))
                .offset(x: 15, y: -34)
            Text("~")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundColor(scratchColor.opacity(scratchPhase ? 0.30 : 0.85))
                .offset(x: 17, y: -35)
        }
    }

    private var scratchColor: Color {
        theme == .pearl ? Color(red: 0.15, green: 0.18, blue: 0.25) : Color.white
    }
}
