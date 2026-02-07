import Foundation
import OpenClawWS

enum OpenClawBootstrap {
    static func makeChatService() throws -> ChatService {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let identityURL = appSupport
            .appendingPathComponent("openclaw", isDirectory: true)
            .appendingPathComponent("device-identity.json")

        let identity = try DeviceIdentityStore.loadOrCreate(storageURL: identityURL)

        let config = GatewayWebSocketClient.Configuration(
            url: OpenClawConfig.gatewayURL,
            token: OpenClawConfig.gatewayToken
        )

        let client = GatewayWebSocketClient(configuration: config, identity: identity)
        return ChatService(client: client)
    }
}
