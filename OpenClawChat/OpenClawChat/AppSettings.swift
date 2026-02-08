import Foundation
import SwiftUI

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Claro"
        case .dark: return "Oscuro"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("themeMode") private var themeModeRaw: String = ThemeMode.system.rawValue

    // MARK: - Connection

    /// Default: Tailscale Serve URL (recommended for Simulator + iPhone).
    @AppStorage("gatewayURL") var gatewayURLString: String = "wss://mac-mini-de-carlos.tail23b32.ts.net"

    /// Auto-connect when the app becomes active.
    @AppStorage("shouldAutoConnect") var shouldAutoConnect: Bool = true

    // MARK: - TTS

    @AppStorage("ttsEnabled") var ttsEnabled: Bool = false

    /// Persisted in Keychain (not UserDefaults).
    @Published var gatewayToken: String {
        didSet {
            GatewayTokenStore.save(gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    init() {
        self.gatewayToken = GatewayTokenStore.load()
    }

    var themeMode: ThemeMode {
        get { ThemeMode(rawValue: themeModeRaw) ?? .system }
        set {
            themeModeRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    var gatewayURL: URL {
        // Normalize empty values back to default.
        let s = gatewayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: s), url.scheme != nil {
            return url
        }
        return URL(string: "wss://mac-mini-de-carlos.tail23b32.ts.net")!
    }
}
