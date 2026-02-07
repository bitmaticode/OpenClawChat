import Foundation
import SwiftUI
import OpenClawWS

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [String] = []
    @Published var draft: String = ""
    @Published var isConnected = false

    private let chatService: ChatService
    private let sessionKey: String
    private var streamTask: Task<Void, Never>?

    init(chatService: ChatService, sessionKey: String) {
        self.chatService = chatService
        self.sessionKey = sessionKey
    }

    func connect() {
        Task {
            do {
                _ = try await chatService.connect()
                isConnected = true
                listen()
            } catch {
                messages.append("❌ Error conectando: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        Task { await chatService.disconnect() }
        isConnected = false
    }

    func sendText() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        messages.append("🧑 \(text)")

        Task {
            do {
                _ = try await chatService.send(sessionKey: sessionKey, text: text)
            } catch {
                messages.append("❌ Error enviando: \(error.localizedDescription)")
            }
        }
    }

    private func listen() {
        streamTask = Task {
            let stream = await chatService.streamChatEvents()
            for await event in stream {
                if event.state == "delta" || event.state == "final" {
                    let text = event.message?.content?.first(where: { $0.type == "text" })?.text ?? ""
                    if !text.isEmpty {
                        messages.append("🤖 \(text)")
                    }
                } else if event.state == "error" {
                    messages.append("⚠️ \(event.errorMessage ?? "Error desconocido")")
                }
            }
        }
    }
}
