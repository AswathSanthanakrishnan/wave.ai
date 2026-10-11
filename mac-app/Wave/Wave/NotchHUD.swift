import AppKit
import SwiftUI
import Combine

// MARK: - Notch HUD Controller

@MainActor
final class NotchHUD: ObservableObject {
    @Published var enabled = false
    @Published private(set) var isVisible = false
    @Published var isPulsing = false

    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var voice: VoiceModel?
    private var actions: ActionRunner?

    func start(voice: VoiceModel, actions: ActionRunner) {
        self.voice = voice
        self.actions = actions
        // Retained in project: presentation stopped as visual feedback is handled by the Living Ball
        if enabled {
            setupPanel()
            setupBindings()
        }
    }

    func pulseWakeWord() {
        guard enabled else { return }
        show()
        isPulsing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            isPulsing = false
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on {
            panel?.orderOut(nil)
            isVisible = false
        } else if panel == nil {
            setupPanel()
            setupBindings()
        }
    }

    private func setupPanel() {
        guard panel == nil else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let geometry = NotchGeometry.detect(on: screen)

        let initialRect = NSRect(
            x: geometry.centerX - geometry.expandedWidth / 2,
            y: screen.frame.maxY - geometry.expandedHeight,
            width: geometry.expandedWidth,
            height: geometry.expandedHeight
        )

        let panel = NSPanel(
            contentRect: initialRect,
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
        panel.setAccessibilityElement(false)

        guard let voice, let actions else { return }
        let contentView = NotchContentView(voice: voice, actions: actions, hud: self)
        panel.contentView = NSHostingView(rootView: contentView)
        self.panel = panel
    }

    private func setupBindings() {
        guard let voice, let actions else { return }

        Publishers.CombineLatest3(
            voice.$listening,
            voice.$isSpeaking,
            voice.$busy
        )
        .combineLatest(actions.$running, actions.$status)
        .receive(on: RunLoop.main)
        .sink { [weak self] (voiceState, actionRunning, actionStatus) in
            guard let self, self.enabled else { return }
            let (listening, speaking, busy) = voiceState
            let shouldBeActive = listening || speaking || busy || actionRunning

            if shouldBeActive {
                self.show()
            }
        }
        .store(in: &cancellables)
    }

    func show() {
        guard enabled, let panel else { return }
        updatePosition()
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    private func updatePosition() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let geometry = NotchGeometry.detect(on: screen)
        let frame = NSRect(
            x: geometry.centerX - geometry.expandedWidth / 2,
            y: screen.frame.maxY - geometry.expandedHeight,
            width: geometry.expandedWidth,
            height: geometry.expandedHeight
        )
        panel.setFrame(frame, display: true)
    }
}

// MARK: - Notch Geometry

struct NotchGeometry {
    let hasNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let centerX: CGFloat
    let expandedWidth: CGFloat = 320
    let expandedHeight: CGFloat = 68

    static func detect(on screen: NSScreen) -> NotchGeometry {
        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           left.width > 0, right.width > 0 {
            let width = right.minX - left.maxX
            let height = screen.frame.maxY - left.minY
            let center = (left.maxX + right.minX) / 2
            return NotchGeometry(
                hasNotch: true,
                notchWidth: max(width, 160),
                notchHeight: max(height, 32),
                centerX: center
            )
        }

        // Fallback for displays without a hardware notch
        return NotchGeometry(
            hasNotch: false,
            notchWidth: 180,
            notchHeight: 32,
            centerX: screen.frame.midX
        )
    }
}

// MARK: - Notch HUD View

private enum HUDState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
}

private struct NotchContentView: View {
    @ObservedObject var voice: VoiceModel
    @ObservedObject var actions: ActionRunner
    @ObservedObject var hud: NotchHUD

    @State private var isExpanded = false
    @State private var collapseTask: Task<Void, Never>?

    private var currentState: HUDState {
        if hud.isPulsing || voice.listening {
            return .listening
        } else if voice.isSpeaking {
            return .speaking
        } else if voice.busy || actions.running {
            return .thinking
        } else {
            return .idle
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if isExpanded {
                ExpandedNotchPill(
                    state: currentState,
                    voiceStatus: voice.status,
                    actionStatus: actions.status,
                    actionRunning: actions.running,
                    isPulsing: hud.isPulsing
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85, anchor: .top).combined(with: .opacity),
                    removal: .scale(scale: 0.85, anchor: .top).combined(with: .opacity)
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: currentState) { newState in
            handleStateChange(newState)
        }
        .onChange(of: hud.isPulsing) { pulsing in
            if pulsing {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                    isExpanded = true
                }
            }
        }
        .onAppear {
            if currentState != .idle || hud.isPulsing {
                isExpanded = true
            }
        }
    }

    private func handleStateChange(_ state: HUDState) {
        collapseTask?.cancel()
        collapseTask = nil

        if state != .idle {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) {
                isExpanded = true
            }
        } else {
            // Give the user a moment to see the final reply or action result before collapsing
            collapseTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isExpanded = false
                }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, currentState == .idle, !hud.isPulsing else { return }
                hud.hide()
            }
        }
    }
}

// MARK: - Expanded Notch Pill View

private struct ExpandedNotchPill: View {
    let state: HUDState
    let voiceStatus: String
    let actionStatus: String
    let actionRunning: Bool
    let isPulsing: Bool

    private var statusTitle: String {
        if isPulsing {
            return "Hey Wave!"
        }
        switch state {
        case .listening:
            return "Listening…"
        case .thinking:
            if actionRunning {
                return actionStatus.isEmpty ? "Executing…" : actionStatus
            }
            return voiceStatus.isEmpty ? "Thinking…" : voiceStatus
        case .speaking:
            return "Wave"
        case .idle:
            return ""
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Gemini-style animated voice & thinking wave
            GeminiWaveVisualizer(state: state)

            // Dynamic status label
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if state == .speaking && !voiceStatus.isEmpty && voiceStatus != "Speaking…" {
                    Text(voiceStatus)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Wave icon indicator
            Image(systemName: state == .listening ? "mic.fill" : "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(iconColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 300, height: 52)
        .scaleEffect(isPulsing ? 1.04 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: isPulsing
                                    ? [Color.cyan, Color.white.opacity(0.8)]
                                    : borderColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isPulsing ? 2.0 : 1.2
                        )
                )
                .shadow(color: (isPulsing ? Color.cyan : glowColor).opacity(isPulsing ? 0.6 : 0.35),
                        radius: isPulsing ? 18 : 14, x: 0, y: 6)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isPulsing)
    }

    private var iconColor: Color {
        switch state {
        case .listening: return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .thinking: return Color(red: 0.75, green: 0.45, blue: 1.0)
        case .speaking: return Color(red: 0.25, green: 0.85, blue: 0.55)
        case .idle: return .white.opacity(0.5)
        }
    }

    private var glowColor: Color {
        switch state {
        case .listening: return Color(red: 0.25, green: 0.55, blue: 1.0)
        case .thinking: return Color(red: 0.65, green: 0.35, blue: 0.95)
        case .speaking: return Color(red: 0.20, green: 0.80, blue: 0.50)
        case .idle: return .clear
        }
    }

    private var borderColors: [Color] {
        switch state {
        case .listening:
            return [Color(red: 0.3, green: 0.6, blue: 1.0).opacity(0.6), Color.white.opacity(0.15)]
        case .thinking:
            return [Color(red: 0.7, green: 0.4, blue: 1.0).opacity(0.6), Color(red: 0.3, green: 0.8, blue: 0.9).opacity(0.3)]
        case .speaking:
            return [Color(red: 0.2, green: 0.85, blue: 0.55).opacity(0.6), Color.white.opacity(0.15)]
        case .idle:
            return [Color.white.opacity(0.12), Color.white.opacity(0.05)]
        }
    }
}

// MARK: - Gemini-Style Animated Wave Visualizer

private struct GeminiWaveVisualizer: View {
    let state: HUDState

    // 4 vertical Gemini-style wave bars
    private let barColors: [Color] = [
        Color(red: 0.26, green: 0.52, blue: 0.96), // Google Blue
        Color(red: 0.61, green: 0.32, blue: 0.88), // Purple
        Color(red: 0.92, green: 0.26, blue: 0.21), // Coral / Pink
        Color(red: 0.00, green: 0.79, blue: 1.00)  // Cyan
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    WaveBar(
                        height: computeHeight(index: index, elapsed: elapsed),
                        color: barColors[index]
                    )
                }
            }
            .frame(width: 38, height: 28)
        }
    }

    private func computeHeight(index: Int, elapsed: Double) -> CGFloat {
        let phase = Double(index) * 0.75
        switch state {
        case .listening:
            // Dynamic oscillating wave moving up and down
            let wave = sin(elapsed * 7.5 + phase) * 0.5 + 0.5
            let wave2 = cos(elapsed * 4.2 + Double(index)) * 0.3 + 0.5
            return 8.0 + CGFloat((wave * 0.7 + wave2 * 0.3) * 20.0)

        case .speaking:
            // Rhythmic speech soundwave bouncing
            let beat = sin(elapsed * 9.0 + phase) * 0.6 + 0.5
            let modulation = sin(elapsed * 3.0) * 0.4 + 0.6
            return 9.0 + CGFloat(beat * modulation * 21.0)

        case .thinking:
            // Gentle breathing pulse
            let pulse = sin(elapsed * 3.5 + phase * 0.5) * 0.5 + 0.5
            return 8.0 + CGFloat(pulse * 10.0)

        case .idle:
            return 6.0
        }
    }
}

private struct WaveBar: View {
    let height: CGFloat
    let color: Color

    var body: some View {
        Capsule(style: .continuous)
            .fill(color)
            .frame(width: 5, height: height)
            .shadow(color: color.opacity(0.55), radius: 3, x: 0, y: 0)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.65), value: height)
    }
}
