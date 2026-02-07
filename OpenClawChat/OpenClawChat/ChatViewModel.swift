import Foundation
import SwiftUI
import OpenClawWS

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var draft: String = ""
    @Published var isConnected = false

    let sessionKey: String
    private let chatService: ChatService
    private var streamTask: Task<Void, Never>?

    init(chatService: ChatService, sessionKey: String) {
        self.chatService = chatService
        self.sessionKey = sessionKey
        items.append(.init(sender: .system, text: "sessionKey=\(sessionKey)", style: .status))
    }

    func connect() {
        guard !OpenClawConfig.gatewayToken.isEmpty else {
            items.append(.init(sender: .system, text: "Falta OPENCLAW_GATEWAY_TOKEN (env var)", style: .error))
            return
        }

        Task {
            do {
                _ = try await chatService.connect()
                isConnected = true
                items.append(.init(sender: .system, text: "Conectado", style: .status))
                listen()
            } catch {
                items.append(.init(sender: .system, text: "Error conectando: \(error.localizedDescription)", style: .error))
            }
        }
    }

    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        Task { await chatService.disconnect() }
        isConnected = false
        items.append(.init(sender: .system, text: "Desconectado", style: .status))
    }

    func sendText() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        items.append(.init(sender: .user, text: text))

        Task {
            do {
                _ = try await chatService.send(sessionKey: sessionKey, text: text)
            } catch {
                items.append(.init(sender: .system, text: "Error enviando: \(error.localizedDescription)", style: .error))
            }
        }
    }

    func sendImage(jpegData: Data, fileName: String = "camera.jpg", caption: String? = nil) {
        let captionText = (caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let label = captionText.isEmpty ? "Imagen" : "Imagen: \(captionText)"
        items.append(.init(sender: .user, text: label))

        Task {
            do {
                _ = try await chatService.send(
                    sessionKey: sessionKey,
                    text: captionText.isEmpty ? "(imagen)" : captionText,
                    attachments: [
                        .image(data: jpegData, mimeType: "image/jpeg", fileName: fileName)
                    ]
                )
            } catch {
                items.append(.init(sender: .system, text: "Error enviando imagen: \(error.localizedDescription)", style: .error))
            }
        }
    }

    private func listen() {
        streamTask = Task {
            let stream = await chatService.streamChatEvents()
            for await event in stream {
                // Important: the gateway can broadcast chat events for other sessions.
                guard event.sessionKey == self.sessionKey else { continue }

                if event.state == "delta" || event.state == "final" {
                    let text = event.message?.content?.first(where: { $0.type == "text" })?.text ?? ""
                    if !text.isEmpty {
                        items.append(.init(sender: .assistant, text: text))
                    }
                } else if event.state == "error" {
                    items.append(.init(sender: .system, text: event.errorMessage ?? "Error desconocido", style: .error))
                }
            }
        }
    }

    func sendPDF(fileURL: URL, prompt: String? = nil) {
        items.append(.init(sender: .user, text: "PDF: \(fileURL.lastPathComponent)"))

        Task {
            do {
                let data = try Data(contentsOf: fileURL)
                let maxBytes = 5_000_000
                if data.count > maxBytes {
                    throw NSError(domain: "OpenClawChat", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "PDF demasiado grande: \(data.count) bytes (máximo \(maxBytes))"
                    ])
                }

                let client = OpenResponsesClient(baseURL: OpenClawConfig.responsesURL, token: OpenClawConfig.gatewayToken, agentId: "opus")
                let question = (prompt?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                let p = question ?? "Analiza este PDF y dame un resumen y puntos clave."

                let answer = try await client.sendPDF(
                    sessionKey: sessionKey,
                    prompt: p,
                    pdfData: data,
                    fileName: fileURL.lastPathComponent
                )

                items.append(.init(sender: .assistant, text: answer))
            } catch {
                items.append(.init(sender: .system, text: "Error enviando PDF: \(error.localizedDescription)", style: .error))
            }
        }
    }
}
