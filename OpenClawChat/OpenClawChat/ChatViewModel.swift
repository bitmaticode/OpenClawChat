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
        messages.append("sessionKey=\(sessionKey)")
    }

    func connect() {
        guard !OpenClawConfig.gatewayToken.isEmpty else {
            messages.append("⚠️ Falta OPENCLAW_GATEWAY_TOKEN (env var)")
            return
        }

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

    func sendImage(jpegData: Data, fileName: String = "camera.jpg", caption: String? = nil) {
        let captionText = (caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !captionText.isEmpty {
            messages.append("🧑 [imagen] \(captionText)")
        } else {
            messages.append("🧑 [imagen]")
        }

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
                messages.append("❌ Error enviando imagen: \(error.localizedDescription)")
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

    func sendPDF(fileURL: URL, prompt: String? = nil) {
        messages.append("🧑 [PDF] \(fileURL.lastPathComponent)")

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

                messages.append("🤖 \(answer)")
            } catch {
                messages.append("❌ Error enviando PDF: \(error.localizedDescription)")
            }
        }
    }
}
