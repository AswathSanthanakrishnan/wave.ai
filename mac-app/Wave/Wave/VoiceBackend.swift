import Foundation
import AppKit

struct VoiceBackend {
    var configuration: URLSessionConfiguration = .ephemeral
    private struct Request: Encodable { let text: String }
    private struct Reply: Decodable { let reply: String }

    struct ModelsReply: Decodable {
        let cloud: [String]
        let local: [String]
    }

    struct SessionSummaryItem: Decodable, Identifiable, Equatable {
        let id: String
        let title: String
        let created_at: String
    }

    private struct GetSessionsReply: Decodable {
        let sessions: [SessionSummaryItem]
    }

    struct SessionMessageItem: Decodable, Identifiable, Equatable {
        let id: String
        let session_id: String
        let role: String
        let text: String
        let model: String?
        let created_at: String
    }

    private struct GetSessionMessagesReply: Decodable {
        let messages: [SessionMessageItem]
    }

    private struct DeleteSessionReply: Decodable {
        let success: Bool
    }

    private struct AgentRequest: Encodable {
        let text: String
        let model: String?
        let session_id: String?
        let pointed_target: PointedContext?
        let running_apps: [String]?
        let frontmost_app: String?
    }

    private static let baseURL = "http://127.0.0.1:4000"

    func models() async throws -> ModelsReply {
        let config = configuration
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/models")!)
        request.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw VoiceError.backendUnavailable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let reply = try? JSONDecoder().decode(ModelsReply.self, from: data) else {
            throw VoiceError.backendResponse
        }
        return reply
    }

    func sessions() async throws -> [SessionSummaryItem] {
        let config = configuration
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/sessions")!)
        request.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            return []
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let reply = try? JSONDecoder().decode(GetSessionsReply.self, from: data) else {
            return []
        }
        return reply.sessions
    }

    func sessionMessages(_ sessionId: String) async throws -> [SessionMessageItem] {
        let config = configuration
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "\(Self.baseURL)/sessions/\(sessionId)/messages") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            return []
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let reply = try? JSONDecoder().decode(GetSessionMessagesReply.self, from: data) else {
            return []
        }
        return reply.messages
    }

    func deleteSession(_ sessionId: String) async throws -> Bool {
        let config = configuration
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "\(Self.baseURL)/sessions/\(sessionId)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            return false
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let reply = try? JSONDecoder().decode(DeleteSessionReply.self, from: data) else {
            return false
        }
        return reply.success
    }

    func agent(_ text: String, model: String? = nil, sessionId: String? = nil, target: PointedContext?) async throws -> AgentReply {
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.localizedName }
        }
        let frontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName
        }
        let config = configuration
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 95
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/agent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AgentRequest(
            text: text,
            model: model,
            session_id: sessionId,
            pointed_target: target,
            running_apps: running,
            frontmost_app: frontmost
        ))
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw VoiceError.backendUnavailable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let reply = try? JSONDecoder().decode(AgentReply.self, from: data) else { throw VoiceError.backendResponse }
        return reply
    }

    func ask(_ text: String) async throws -> String {
        let config = configuration
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 95
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/ask")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(text: text))
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw VoiceError.backendUnavailable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceError.backendResponse
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              !reply.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceError.backendResponse
        }
        return reply.reply
    }
}

/// Never follow a backend redirect to another host or a cloud service.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
