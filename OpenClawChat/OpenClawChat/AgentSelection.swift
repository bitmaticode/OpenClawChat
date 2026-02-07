import Foundation

enum AgentId: String, CaseIterable, Identifiable, Sendable {
    case main
    case opus
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .main: return "Bit (main)"
        case .opus: return "Opus"
        case .codex: return "Codex"
        }
    }

    /// Useful to show risk/warnings in UI if needed.
    var detail: String? {
        switch self {
        case .main:
            return "Agente principal"
        case .opus:
            return "Rápido y estable"
        case .codex:
            return "Puede requerir re-auth si falla OAuth"
        }
    }
}

enum SessionKeyTools {
    /// Replaces the agent segment in a sessionKey that looks like: agent:<agentId>:<rest...>
    /// If the format is unexpected, falls back to agent:<agentId>:openclawchat.
    static func withAgent(_ agent: AgentId, baseSessionKey: String) -> String {
        let parts = baseSessionKey.lowercased().split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "agent" else {
            return "agent:\(agent.rawValue):openclawchat"
        }

        var newParts = parts
        newParts[1] = Substring(agent.rawValue)
        return newParts.joined(separator: ":")
    }

    static func agent(from sessionKey: String) -> AgentId? {
        let parts = sessionKey.lowercased().split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "agent" else { return nil }
        return AgentId(rawValue: String(parts[1]))
    }
}
