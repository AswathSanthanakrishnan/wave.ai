import Foundation
import Combine
import SwiftUI

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatRole
    let text: String
    let model: String?
    let timestamp: Date

    init(id: UUID = UUID(), role: ChatRole, text: String, model: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.model = model
        self.timestamp = timestamp
    }
}

enum BrainChoice: Equatable {
    case auto
    case preferCloud
    case preferLocal
    case specificCloud(String)
    case specificLocal(String)

    var modelParameter: String {
        switch self {
        case .auto:
            return "auto"
        case .preferCloud:
            return "cloud"
        case .preferLocal:
            return "local"
        case .specificCloud(let id):
            return "cloud:\(id)"
        case .specificLocal(let name):
            return "local:\(name)"
        }
    }

    var displayTitle: String {
        switch self {
        case .auto:
            return "Auto"
        case .preferCloud:
            return "Prefer Cloud"
        case .preferLocal:
            return "Prefer Local"
        case .specificCloud(let id):
            let short = id.split(separator: "/").last.map(String.init) ?? id
            return "Cloud: \(short)"
        case .specificLocal(let name):
            return "Local: \(name)"
        }
    }

    var rawValue: String {
        switch self {
        case .auto:
            return "auto"
        case .preferCloud:
            return "cloud"
        case .preferLocal:
            return "local"
        case .specificCloud(let id):
            return "cloud:\(id)"
        case .specificLocal(let name):
            return "local:\(name)"
        }
    }

    init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "auto" {
            self = .auto
        } else if trimmed == "cloud" {
            self = .preferCloud
        } else if trimmed == "local" {
            self = .preferLocal
        } else if trimmed.hasPrefix("cloud:") {
            let id = String(trimmed.dropFirst("cloud:".count))
            self = .specificCloud(id)
        } else if trimmed.hasPrefix("local:") {
            let name = String(trimmed.dropFirst("local:".count))
            self = .specificLocal(name)
        } else {
            self = .auto
        }
    }
}

@MainActor
protocol VoiceCommandExecuting: AnyObject {
    var brain: String { get }
    func executeTypedCommand(_ text: String, model: String, sessionId: String?) async
}

@MainActor
final class ChatSessionModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isPinned: Bool = false
    @Published var brainChoice: BrainChoice {
        didSet {
            UserDefaults.standard.set(brainChoice.rawValue, forKey: "wave_brain_choice")
        }
    }
    @Published var cloudModels: [String] = ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "llama-3.3-70b-versatile"]
    @Published var localModels: [String] = ["ornith:9b"]
    @Published var isSending: Bool = false
    @Published var isLoadingModels: Bool = false
    @Published var currentSessionId: String? = nil
    @Published var currentSessionTitle: String? = nil
    @Published var pastSessions: [VoiceBackend.SessionSummaryItem] = []

    /// The exact string formatted for /agent's "model" parameter
    var activeModelParameter: String {
        brainChoice.modelParameter
    }

    func setBrainChoice(_ choice: BrainChoice) {
        self.brainChoice = choice
    }

    private let backend = VoiceBackend()
    private weak var voiceModel: (any VoiceCommandExecuting)?
    private var hasExplicitlyStartedNewChat = false

    init() {
        let saved = UserDefaults.standard.string(forKey: "wave_brain_choice") ?? "auto"
        self.brainChoice = BrainChoice(rawValue: saved)
        Task { [weak self] in
            await self?.fetchModels()
            await self?.loadLatestSessionOnOpen()
        }
    }

    func setVoiceModel(_ voice: any VoiceCommandExecuting) {
        self.voiceModel = voice
    }

    func fetchModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let res = try await backend.models()
            if !res.cloud.isEmpty {
                self.cloudModels = res.cloud
            }
            if !res.local.isEmpty {
                self.localModels = res.local
            }
        } catch {
            // Keep default fallback lists if backend endpoint is unavailable
        }
    }

    func refreshSessions() async {
        do {
            let sessions = try await backend.sessions()
            self.pastSessions = sessions
        } catch {
            // Backend offline or database not yet ready
        }
    }

    func loadLatestSessionOnOpen() async {
        guard !hasExplicitlyStartedNewChat else { return }
        await refreshSessions()
        if messages.isEmpty, let latest = pastSessions.first {
            await switchToSession(latest)
        }
    }

    func startNewChat() {
        hasExplicitlyStartedNewChat = true
        currentSessionId = nil
        currentSessionTitle = nil
        messages = []
    }

    func switchToSession(_ session: VoiceBackend.SessionSummaryItem) async {
        hasExplicitlyStartedNewChat = false
        currentSessionId = session.id
        currentSessionTitle = session.title
        isSending = true
        defer { isSending = false }
        do {
            let items = try await backend.sessionMessages(session.id)
            self.messages = items.map { item in
                ChatMessage(
                    role: item.role.lowercased() == "user" ? .user : .assistant,
                    text: item.text,
                    model: item.model
                )
            }
        } catch {
            // Failed to fetch session messages
        }
    }

    func deleteSession(_ sessionId: String) async {
        _ = try? await backend.deleteSession(sessionId)
        if currentSessionId == sessionId {
            startNewChat()
        }
        await refreshSessions()
    }

    func addMessage(role: ChatRole, text: String, model: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: role, text: trimmed, model: model))
    }

    func sendCurrentInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        inputText = ""
        hasExplicitlyStartedNewChat = false
        addMessage(role: .user, text: text)
        guard let voice = voiceModel else { return }
        isSending = true
        let sessionToSend = currentSessionId
        Task { [weak self] in
            guard let self else { return }
            await voice.executeTypedCommand(text, model: self.activeModelParameter, sessionId: sessionToSend)
            self.isSending = false
            await self.refreshSessions()
        }
    }
}
