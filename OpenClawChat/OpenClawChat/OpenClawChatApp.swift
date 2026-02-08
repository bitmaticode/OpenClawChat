import SwiftUI

@main
struct OpenClawChatApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            let service = try! OpenClawBootstrap.makeChatService(
                gatewayURL: settings.gatewayURL,
                token: settings.gatewayToken
            )

            ContentView(
                vm: .init(
                    chatService: service,
                    sessionKey: OpenClawConfig.sessionKey,
                    initialGatewayURL: settings.gatewayURL,
                    initialToken: settings.gatewayToken,
                    makeChatService: { url, token in
                        try OpenClawBootstrap.makeChatService(gatewayURL: url, token: token)
                    }
                ),
                settings: settings
            )
            .preferredColorScheme(settings.themeMode.colorScheme)
        }
    }
}
