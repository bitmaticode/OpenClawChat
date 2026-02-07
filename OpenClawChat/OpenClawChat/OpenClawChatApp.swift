import SwiftUI

@main
struct OpenClawChatApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            let service = try! OpenClawBootstrap.makeChatService()
            ContentView(
                vm: .init(chatService: service, sessionKey: OpenClawConfig.sessionKey),
                settings: settings
            )
            .preferredColorScheme(settings.themeMode.colorScheme)
        }
    }
}
