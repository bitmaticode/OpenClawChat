import SwiftUI

@main
struct OpenClawChatApp: App {
    var body: some Scene {
        WindowGroup {
            let service = try! OpenClawBootstrap.makeChatService()
            ContentView(vm: .init(chatService: service, sessionKey: OpenClawConfig.sessionKey))
        }
    }
}
