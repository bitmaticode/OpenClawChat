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

    /// Provide at runtime with env var: OPENCLAW_GATEWAY_TOKEN
    static var gatewayToken: String {
        ProcessInfo.processInfo.environment["OPENCLAW_GATEWAY_TOKEN"] ?? ""
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
