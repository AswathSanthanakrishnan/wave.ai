import AppKit
import SwiftUI
import Combine

// MARK: - Native Floating Key-Capable Panel

final class WaveChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Chat Panel Controller

@MainActor
final class WaveChatController: ObservableObject {
    let chatModel: ChatSessionModel
    @Published private(set) var isVisible = false

    private var panel: WaveChatPanel?
    private var hideTimer: Timer?
    private var isBallHovered = false
    private var isPanelHovered = false
    private var lastBallFrame: CGRect = .zero

    init(chatModel: ChatSessionModel) {
        self.chatModel = chatModel
    }

    func setupPanel() {
        guard panel == nil else { return }

        let panelSize = CGSize(width: 340, height: 460)
        let initialRect = CGRect(origin: CGPoint(x: 100, y: 100), size: panelSize)

        let p = WaveChatPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        let rootView = WaveChatView(chatModel: chatModel, controller: self)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = hostingView
        self.panel = p
    }

    func handleBallHover(_ hovered: Bool, ballFrame: CGRect) {
        isBallHovered = hovered
        lastBallFrame = ballFrame

        if hovered {
            cancelHideTimer()
            showPanel(near: ballFrame)
        } else {
            scheduleHideIfNeeded()
        }
    }

    func handlePanelHover(_ hovered: Bool) {
        isPanelHovered = hovered
        if hovered {
            cancelHideTimer()
        } else {
            scheduleHideIfNeeded()
        }
    }

    func updatePosition(relativeTo ballFrame: CGRect) {
        lastBallFrame = ballFrame
        guard isVisible, let panel else { return }
        let targetOrigin = calculatePanelOrigin(for: ballFrame, panelSize: panel.frame.size)
        panel.setFrameOrigin(targetOrigin)
    }

    func showPanel(near ballFrame: CGRect) {
        setupPanel()
        guard let panel else { return }

        let panelSize = CGSize(width: 340, height: 460)
        let targetOrigin = calculatePanelOrigin(for: ballFrame, panelSize: panelSize)

        if !isVisible {
            Task { [weak self] in
                await self?.chatModel.loadLatestSessionOnOpen()
            }
            // Slide in animation from near ball
            let startOrigin = CGPoint(x: targetOrigin.x - 16, y: targetOrigin.y)
            panel.setFrame(CGRect(origin: startOrigin, size: panelSize), display: true)
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(targetOrigin)
                panel.animator().alphaValue = 1.0
            }
            isVisible = true
        } else {
            panel.setFrameOrigin(targetOrigin)
        }
    }

    func hidePanel() {
        guard isVisible, !chatModel.isPinned, let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.chatModel.isPinned else { return }
                self.panel?.orderOut(nil)
                self.isVisible = false
            }
        })
    }

    private func scheduleHideIfNeeded() {
        guard !chatModel.isPinned else { return }
        guard !isBallHovered && !isPanelHovered else { return }
        cancelHideTimer()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isBallHovered && !self.isPanelHovered && !self.chatModel.isPinned {
                    self.hidePanel()
                }
            }
        }
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func calculatePanelOrigin(for ballFrame: CGRect, panelSize: CGSize) -> CGPoint {
        let screen = panel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Default: docked to the right of the ball with a 12pt gap
        var x = ballFrame.maxX + 12
        // Center vertically with ball
        var y = ballFrame.midY - panelSize.height / 2

        // If overflowing right edge of screen, dock to the left of the ball
        if x + panelSize.width > screen.maxX - 8 {
            x = ballFrame.minX - panelSize.width - 12
        }

        // Clamp to screen bounds
        x = max(screen.minX + 8, min(x, screen.maxX - panelSize.width - 8))
        y = max(screen.minY + 8, min(y, screen.maxY - panelSize.height - 8))

        return CGPoint(x: x, y: y)
    }
}

// MARK: - Native Liquid Glass Chat View

struct WaveChatView: View {
    @ObservedObject var chatModel: ChatSessionModel
    @ObservedObject var controller: WaveChatController
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header: Model Switcher & Pin
            headerBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()
                .background(Color.white.opacity(0.10))

            // Conversation Messages Area
            conversationArea

            Divider()
                .background(Color.white.opacity(0.10))

            // Text Input Field Area
            inputBar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 340, height: 460)
        // Native liquid glass backdrop
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.22)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.38), radius: 18, x: 0, y: 8)
        .onHover { hovered in
            controller.handlePanelHover(hovered)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(chatModel.currentSessionTitle ?? "Wave")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.90))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Past Chats History Menu
            historyMenuButton

            // New Chat Button
            Button(action: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    chatModel.startNewChat()
                }
            }) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.75))
                    .padding(5)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Start new chat session")

            // Pin Button
            Button(action: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    chatModel.isPinned.toggle()
                }
            }) {
                Image(systemName: chatModel.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(chatModel.isPinned ? Color(red: 0.38, green: 0.72, blue: 0.98) : Color.white.opacity(0.65))
                    .padding(5)
                    .background(chatModel.isPinned ? Color.white.opacity(0.12) : Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(chatModel.isPinned ? "Unpin chat panel" : "Pin chat panel open")
        }
    }

    private var historyMenuButton: some View {
        Menu {
            Button(action: {
                chatModel.startNewChat()
            }) {
                Label("New Chat", systemImage: "plus")
            }
            Divider()
            if chatModel.pastSessions.isEmpty {
                Text("No saved chats")
            } else {
                ForEach(chatModel.pastSessions) { session in
                    Button(action: {
                        Task { await chatModel.switchToSession(session) }
                    }) {
                        if chatModel.currentSessionId == session.id {
                            Text("✓ \(session.title)")
                        } else {
                            Text(session.title)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.75))
                .padding(5)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .help("Recent chats")
        .onTapGesture {
            Task { await chatModel.refreshSessions() }
        }
    }

    // MARK: - Conversation Messages List

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 10) {
                    if chatModel.messages.isEmpty {
                        emptyStateView
                            .padding(.top, 60)
                    } else {
                        ForEach(chatModel.messages) { msg in
                            messageBubble(for: msg)
                                .id(msg.id)
                        }
                    }

                    if chatModel.isSending {
                        thinkingIndicator
                            .id("thinking_indicator")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: chatModel.messages.count) { _, _ in
                if let last = chatModel.messages.last {
                    withAnimation(.easeOut(duration: 0.20)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chatModel.isSending) { _, isSending in
                if isSending {
                    withAnimation {
                        proxy.scrollTo("thinking_indicator", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundColor(Color(red: 0.38, green: 0.72, blue: 0.98).opacity(0.85))

            Text(chatModel.currentSessionTitle ?? "Wave v2")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 24)

            Text(chatModel.currentSessionTitle != nil ? "Continuing this conversation…" : "Type below to command your Mac, or click the ball to speak.")
                .font(.system(size: 11.5, weight: .regular))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private func messageBubble(for msg: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            if msg.role == .assistant {
                // Assistant message on left
                Circle()
                    .fill(Color(red: 0.38, green: 0.72, blue: 0.98))
                    .frame(width: 5, height: 5)
                    .padding(.bottom, 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(msg.text)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundColor(.white.opacity(0.95))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7.5)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.09))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                        )

                    if let model = msg.model, !model.isEmpty {
                        let caption = model.lowercased().contains("local") ? "via local" : "via cloud"
                        Text(caption)
                            .font(.system(size: 9.5, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.38))
                            .padding(.leading, 3)
                    }
                }
                Spacer(minLength: 28)
            } else {
                // User message on right
                Spacer(minLength: 28)
                Text(msg.text)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundColor(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7.5)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.16, green: 0.42, blue: 0.88),
                                        Color(red: 0.10, green: 0.30, blue: 0.75)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    )
            }
        }
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(red: 0.38, green: 0.72, blue: 0.98))
                .frame(width: 5, height: 5)

            Text("Wave is thinking…")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.60))

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            HStack {
                TextField("Ask Wave or command Mac…", text: $chatModel.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white)
                    .focused($isFieldFocused)
                    .onSubmit {
                        chatModel.sendCurrentInput()
                    }

                if !chatModel.inputText.isEmpty {
                    Button(action: { chatModel.inputText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.40))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(isFieldFocused ? 0.30 : 0.12), lineWidth: 1)
            )

            // Send button
            Button(action: {
                chatModel.sendCurrentInput()
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(
                        chatModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatModel.isSending ?
                            Color.white.opacity(0.25) :
                            Color(red: 0.28, green: 0.65, blue: 0.98)
                    )
            }
            .buttonStyle(.plain)
            .disabled(chatModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatModel.isSending)
        }
    }
}

// MARK: - AppKit Visual Effect View Blur Helper

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
