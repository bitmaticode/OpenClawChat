import Foundation
import SwiftUI
import OpenClawWS

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var draft: String = ""
    @Published var isConnected = false

    @Published var selectedAgent: AgentId
    @Published private(set) var sessionKey: String

    private let baseSessionKey: String
    private var chatService: ChatService
    private let makeChatService: (URL, String) throws -> ChatService

    private var streamTask: Task<Void, Never>?

    private var cachedThreads: [String: [ChatItem]] = [:]

    // Streaming aggregation (so deltas update a single bubble instead of creating many).
    private var streamingRunId: String?
    private var streamingItemId: UUID?
    private var streamingLastSeq: Int?

    // TTS
    private let speech = SpeechManager()

    init(chatService: ChatService, sessionKey: String, makeChatService: @escaping (URL, String) throws -> ChatService) {
        self.chatService = chatService
        self.makeChatService = makeChatService
        self.baseSessionKey = sessionKey.lowercased()

        let agent = SessionKeyTools.selection(from: sessionKey) ?? .opus
        self.selectedAgent = agent
        self.sessionKey = SessionKeyTools.sessionKey(for: agent, baseSessionKey: self.baseSessionKey)

        items = Self.bootstrapItems(sessionKey: self.sessionKey, agent: agent)
    }

    private static func bootstrapItems(sessionKey: String, agent: AgentId) -> [ChatItem] {
        [
            .init(sender: .system, text: "Agente: \(agent.title)", style: .status),
            .init(sender: .system, text: "sessionKey=\(sessionKey)", style: .status)
        ]
    }

    func setTTSEnabled(_ enabled: Bool) {
        speech.isEnabled = enabled
    }

    func reconfigureConnection(gatewayURL: URL, token: String) {
        let wasConnected = isConnected
        if wasConnected { disconnect(showStatus: false) }

        do {
            self.chatService = try makeChatService(gatewayURL, token)
            items.append(.init(sender: .system, text: "Configuración actualizada", style: .status))
        } catch {
            items.append(.init(sender: .system, text: "Error creando cliente: \(error.localizedDescription)", style: .error))
        }

        if wasConnected {
            connect()
        }
    }

    func connect() {
        guard !OpenClawConfig.gatewayToken.isEmpty else {
            items.append(.init(sender: .system, text: "Falta el token del gateway. Ponlo en Menú → Gateway o como OPENCLAW_GATEWAY_TOKEN (env var).", style: .error))
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

    func disconnect(showStatus: Bool = true) {
        streamTask?.cancel()
        streamTask = nil
        speech.stop()
        Task { await chatService.disconnect() }
        isConnected = false
        if showStatus {
            items.append(.init(sender: .system, text: "Desconectado", style: .status))
        }
    }

    func applySelectedAgent(_ agent: AgentId) {
        let newKey = SessionKeyTools.sessionKey(for: agent, baseSessionKey: baseSessionKey)
        guard newKey != sessionKey else { return }

        // Cache current thread.
        cachedThreads[sessionKey] = items

        let wasConnected = isConnected
        if wasConnected {
            disconnect(showStatus: false)
        } else {
            // Even if disconnected, stop any ongoing TTS.
            speech.stop()
        }

        sessionKey = newKey

        // Restore or bootstrap thread.
        if let cached = cachedThreads[newKey] {
            items = cached
        } else {
            items = Self.bootstrapItems(sessionKey: newKey, agent: agent)
        }

        if wasConnected {
            connect()
        }
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
                    let newText = event.message?.content?.first(where: { $0.type == "text" })?.text ?? ""
                    if !newText.isEmpty {
                        applyStreamingText(newText, runId: event.runId, seq: event.seq, isFinal: event.state == "final")
                    } else if event.state == "final" {
                        speech.append(delta: "", isFinal: true)
                    }

                    if event.state == "final" {
                        streamingRunId = nil
                        streamingItemId = nil
                        streamingLastSeq = nil
                    }
                } else if event.state == "error" {
                    streamingRunId = nil
                    streamingItemId = nil
                    streamingLastSeq = nil
                    speech.stop()
                    items.append(.init(sender: .system, text: event.errorMessage ?? "Error desconocido", style: .error))
                }
            }
        }
    }

    private func applyStreamingText(_ newText: String, runId: String, seq: Int, isFinal: Bool) {
        // If this is a new run, start a new assistant bubble.
        if streamingRunId != runId || streamingItemId == nil {
            let item = ChatItem(sender: .assistant, text: newText)
            streamingRunId = runId
            streamingItemId = item.id
            streamingLastSeq = seq
            items.append(item)

            // For TTS, treat first chunk as delta.
            speech.append(delta: newText, isFinal: isFinal)
            return
        }

        // Drop out-of-order seqs (shouldn't happen, but protects against reconnect weirdness).
        if let last = streamingLastSeq, seq < last {
            return
        }
        streamingLastSeq = seq

        guard let id = streamingItemId,
              let idx = items.lastIndex(where: { $0.id == id }) else {
            // Fallback: create a new bubble.
            let item = ChatItem(sender: .assistant, text: newText)
            streamingRunId = runId
            streamingItemId = item.id
            items.append(item)
            return
        }

        let current = items[idx].text
        let merged = mergeStreamingText(current: current, incoming: newText)
        items[idx].text = merged.merged

        if !merged.appended.isEmpty || isFinal {
            speech.append(delta: merged.appended, isFinal: isFinal)
        }
    }

    /// Some gateways send true deltas (append-only), others send the full text-so-far.
    /// This tries to do the right thing without duplicating content.
    private func mergeStreamingText(current: String, incoming: String) -> (merged: String, appended: String) {
        if current.isEmpty { return (incoming, incoming) }

        // Cumulative update: incoming contains current as prefix.
        if incoming.hasPrefix(current) {
            let delta = String(incoming.dropFirst(current.count))
            return (incoming, delta)
        }

        // If current already ends with incoming (duplicate), keep current.
        if current.hasSuffix(incoming) { return (current, "") }

        // If incoming is a strict prefix of current (rare), keep the longer one.
        if current.hasPrefix(incoming) { return (current, "") }

        // Otherwise treat as delta.
        return (current + incoming, incoming)
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

                let client = OpenResponsesClient(baseURL: OpenClawConfig.responsesURL, token: OpenClawConfig.gatewayToken, agentId: selectedAgent.rawValue)
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
