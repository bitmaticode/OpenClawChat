import Foundation

enum OpenClawConfig {
    /// Default: Tailscale Serve URL (recommended for Simulator + iPhone).
    /// Override at runtime with env var: OPENCLAW_GATEWAY_URL
    static var gatewayURL: URL {
        if let s = ProcessInfo.processInfo.environment["OPENCLAW_GATEWAY_URL"],
           let url = URL(string: s) {
            return url
        }
        return URL(string: "wss://mac-mini-de-carlos.tail23b32.ts.net")!
    }

    /// OpenResponses HTTP endpoint base.
    /// Override at runtime with env var: OPENCLAW_RESPONSES_URL
    static var responsesURL: URL {
        if let s = ProcessInfo.processInfo.environment["OPENCLAW_RESPONSES_URL"],
           let url = URL(string: s) {
            return url
        }
        return URL(string: "https://mac-mini-de-carlos.tail23b32.ts.net/v1/responses")!
    }

    /// Provide at runtime with env var: OPENCLAW_GATEWAY_TOKEN
    /// or set it from the in-app Settings menu (stored in Keychain).
    static var gatewayToken: String {
        if let t = ProcessInfo.processInfo.environment["OPENCLAW_GATEWAY_TOKEN"], !t.isEmpty {
            return t
        }
        return GatewayTokenStore.load()
    }

    /// Default routes to the Opus agent session to avoid Codex OAuth dependency.
    /// Override at runtime with env var: OPENCLAW_SESSION_KEY
    static var sessionKey: String {
        // Gateway normalizes session keys to lowercase when persisting.
        // Keep the client consistent to avoid confusing history lookups.
        let raw = ProcessInfo.processInfo.environment["OPENCLAW_SESSION_KEY"] ?? "agent:opus:openclawchat"
        return raw.lowercased()
    }
}
