import Foundation

struct PointedContext: Codable, Equatable {
    let app: String
    let kind: String
    let title: String?
}

enum AgentAction: Decodable {
    case openApp(String), closeApp(String), lowPower(Bool), darkMode(Bool)
    case volume(Int), mute(Bool), closeThis, minimizeThis, openThis, minimizeFront
    case install(String), openURL(URL), typeText(String), pressKey(String)
    case wait(Double)
    case clickElement(app: String, label: String)

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
        init(stringValue: String) { self.stringValue = stringValue }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        func key(_ s: String) -> DynamicKey { DynamicKey(stringValue: s) }

        // Find tool name from 'tool', 'name', or 'action'
        var toolName: String?
        if let t = try? c.decode(String.self, forKey: key("tool")) {
            toolName = t
        } else if let t = try? c.decode(String.self, forKey: key("name")) {
            toolName = t
        } else if let t = try? c.decode(String.self, forKey: key("action")) {
            toolName = t
        }

        guard let tool = toolName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !tool.isEmpty else {
            throw ActionError.invalidAction
        }

        // Support nested arguments: { "args": { ... } } or { "arguments": { ... } } or { "parameters": { ... } }
        var argsContainer: KeyedDecodingContainer<DynamicKey>?
        if c.contains(key("args")), let nested = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: key("args")) {
            argsContainer = nested
        } else if c.contains(key("arguments")), let nested = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: key("arguments")) {
            argsContainer = nested
        } else if c.contains(key("parameters")), let nested = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: key("parameters")) {
            argsContainer = nested
        }

        func textParam(_ names: String...) -> String? {
            for name in names {
                let k = key(name)
                if let val = (try? c.decode(String.self, forKey: k)) ?? (try? argsContainer?.decode(String.self, forKey: k)) {
                    let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !trimmed.contains("\0") { return trimmed }
                }
            }
            return nil
        }

        func boolParam(_ names: String...) -> Bool? {
            for name in names {
                let k = key(name)
                if let val = (try? c.decode(Bool.self, forKey: k)) ?? (try? argsContainer?.decode(Bool.self, forKey: k)) {
                    return val
                }
                if let intVal = (try? c.decode(Int.self, forKey: k)) ?? (try? argsContainer?.decode(Int.self, forKey: k)) {
                    return intVal != 0
                }
                if let strVal = (try? c.decode(String.self, forKey: k)) ?? (try? argsContainer?.decode(String.self, forKey: k)) {
                    let s = strVal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if ["true", "1", "yes", "on"].contains(s) { return true }
                    if ["false", "0", "no", "off"].contains(s) { return false }
                }
            }
            return nil
        }

        func intParam(_ names: String...) -> Int? {
            for name in names {
                let k = key(name)
                if let val = (try? c.decode(Int.self, forKey: k)) ?? (try? argsContainer?.decode(Int.self, forKey: k)) {
                    return val
                }
                if let strVal = (try? c.decode(String.self, forKey: k)) ?? (try? argsContainer?.decode(String.self, forKey: k)) {
                    if let parsed = Int(strVal.trimmingCharacters(in: .whitespacesAndNewlines)) { return parsed }
                }
            }
            return nil
        }

        func doubleParam(_ names: String...) -> Double? {
            for name in names {
                let k = key(name)
                if let val = (try? c.decode(Double.self, forKey: k)) ?? (try? argsContainer?.decode(Double.self, forKey: k)) {
                    return val
                }
                if let intVal = (try? c.decode(Int.self, forKey: k)) ?? (try? argsContainer?.decode(Int.self, forKey: k)) {
                    return Double(intVal)
                }
                if let strVal = (try? c.decode(String.self, forKey: k)) ?? (try? argsContainer?.decode(String.self, forKey: k)) {
                    if let parsed = Double(strVal.trimmingCharacters(in: .whitespacesAndNewlines)) { return parsed }
                }
            }
            return nil
        }

        // Whitelisted tools only. Strict check against whitelist.
        switch tool {
        case "open_app":
            guard let app = textParam("app", "name") else { throw ActionError.invalidAction }
            self = .openApp(app)

        case "close_app":
            guard let app = textParam("app", "name") else { throw ActionError.invalidAction }
            self = .closeApp(app)

        case "set_low_power_mode":
            guard let on = boolParam("on", "enabled") else { throw ActionError.invalidAction }
            self = .lowPower(on)

        case "set_dark_mode":
            guard let on = boolParam("on", "enabled") else { throw ActionError.invalidAction }
            self = .darkMode(on)

        case "mute":
            guard let on = boolParam("on", "enabled", "muted") else { throw ActionError.invalidAction }
            self = .mute(on)

        case "set_volume":
            guard let level = intParam("level", "volume"), (0...100).contains(level) else {
                throw ActionError.invalidAction
            }
            self = .volume(level)

        case "close_this":
            self = .closeThis

        case "minimize_this":
            self = .minimizeThis

        case "open_this":
            self = .openThis

        case "minimize_front_window":
            self = .minimizeFront

        case "install_app":
            guard let name = textParam("name", "app") else { throw ActionError.invalidAction }
            self = .install(name)

        case "open_url":
            guard var urlStr = textParam("url") else { throw ActionError.invalidAction }
            if !urlStr.contains("://") { urlStr = "https://" + urlStr }
            guard let url = URL(string: urlStr),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil else {
                throw ActionError.invalidAction
            }
            self = .openURL(url)

        case "type_text":
            guard let text = textParam("text", "content") else { throw ActionError.invalidAction }
            self = .typeText(text)

        case "press_key":
            guard let key = textParam("key")?.lowercased() else { throw ActionError.invalidAction }
            let allowed = ["escape", "esc", "enter", "return", "space", "tab", "delete", "backspace", "up", "down", "left", "right"]
            guard allowed.contains(key) else { throw ActionError.invalidAction }
            self = .pressKey(key)

        case "wait":
            guard let seconds = doubleParam("seconds", "duration", "time"), (0.5...5.0).contains(seconds) else {
                throw ActionError.invalidAction
            }
            self = .wait(seconds)

        case "click_element":
            guard let app = textParam("app"), let label = textParam("label") else {
                throw ActionError.invalidAction
            }
            self = .clickElement(app: app, label: label)

        default:
            throw ActionError.invalidAction
        }
    }

    var label: String {
        switch self {
        case .openApp(let x): return "Open \(x)"
        case .closeApp(let x): return "Quit \(x)"
        case .lowPower(let x): return "Low Power Mode \(x ? "On" : "Off")"
        case .darkMode(let x): return "Dark Mode \(x ? "On" : "Off")"
        case .volume(let x): return "Volume \(x)%"
        case .mute(let x): return "Mute \(x ? "On" : "Off")"
        case .closeThis: return "Close highlighted target"
        case .minimizeThis: return "Minimize highlighted window"
        case .openThis: return "Open highlighted target"
        case .minimizeFront: return "Minimize front window"
        case .install(let x): return "Install \(x)"
        case .openURL(let x): return "Open \(x.host ?? "URL")"
        case .typeText: return "Type text"
        case .pressKey(let x): return "Press \(x)"
        case .wait(let x): return "Wait \(x)s"
        case .clickElement(let app, let label): return "Click \(label) in \(app)"
        }
    }
}

struct AgentReply: Decodable {
    let reply: String
    let actions: [AgentAction]
    let rejected: Int
    let model: String?
    let session_id: String?
    private enum CodingKeys: String, CodingKey { case reply, actions, model, session_id }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = (try? c.decode(String.self, forKey: .reply)) ?? ""
        model = try? c.decode(String.self, forKey: .model)
        session_id = try? c.decode(String.self, forKey: .session_id)
        var valid: [AgentAction] = []
        var dropped = 0
        if var list = try? c.nestedUnkeyedContainer(forKey: .actions) {
            while !list.isAtEnd {
                let item = try list.superDecoder()
                if let action = try? AgentAction(from: item) {
                    valid.append(action)
                } else {
                    dropped += 1
                }
            }
        }
        actions = valid
        rejected = dropped
    }
}

enum ActionError: LocalizedError {
    case invalidAction, failed(String)
    var errorDescription: String? {
        switch self {
        case .invalidAction: return "Rejected an invalid action"
        case .failed(let message): return message
        }
    }
}
