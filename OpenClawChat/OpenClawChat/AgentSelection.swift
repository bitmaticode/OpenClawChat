import Foundation

enum AgentId: String, CaseIterable, Identifiable, Sendable {
    /// "Main" in OpenClaw isn't an agent id; it's the special sessionKey `agent:codex:main`.
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

    /// Short name to show in the top bar.
    var shortTitle: String {
        switch self {
        case .main: return "Bit"
        case .opus: return "Opus"
        case .codex: return "Codex"
        }
    }

    /// Useful to show risk/warnings in UI if needed.
    var detail: String? {
        switch self {
        case .main:
            return "Sesión principal (agent:codex:main)"
        case .opus:
            return "Rápido y estable"
        case .codex:
            return "Puede requerir re-auth si falla OAuth"
        }
    }
}

enum SessionKeyTools {
    /// Returns the sessionKey that should be used for a given agent selection.
    ///
    /// Notes:
    /// - `.main` maps to the special session key `agent:codex:main`.
    /// - `.opus` / `.codex` rewrite only the agent segment: `agent:<agent>:<rest...>`
    static func sessionKey(for agent: AgentId, baseSessionKey: String) -> String {
        switch agent {
        case .main:
            return "agent:codex:main"
        case .opus, .codex:
            return withAgentSegment(agent.rawValue, baseSessionKey: baseSessionKey)
        }
    }

    private static func withAgentSegment(_ agentId: String, baseSessionKey: String) -> String {
        let parts = baseSessionKey.lowercased().split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "agent" else {
            return "agent:\(agentId):openclawchat"
        }

        var newParts = parts
        newParts[1] = Substring(agentId)
        return newParts.joined(separator: ":")
    }

    static func selection(from sessionKey: String) -> AgentId? {
        let parts = sessionKey.lowercased().split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "agent" else { return nil }

        // Special-case: main session.
        if parts[1] == "codex", parts[2] == "main" {
            return .main
        }

        return AgentId(rawValue: String(parts[1]))
    }
}
