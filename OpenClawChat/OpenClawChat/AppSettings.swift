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
}
