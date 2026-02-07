import Foundation

public actor ChatService {
    public struct HistoryMessage: Codable, Sendable {
        public struct ContentBlock: Codable, Sendable {
            public let type: String
            public let text: String?
        }

        public let role: String?
        public let content: [ContentBlock]?
        public let timestamp: Int64?
    }

    public struct ChatHistoryResponse: Codable, Sendable {
        public let sessionKey: String
        public let messages: [HistoryMessage]
    }

    private let client: GatewayWebSocketClient
    private let attachmentPipeline: AttachmentPipeline

    private var eventStreams: [UUID: AsyncStream<ChatEventPayload>.Continuation] = [:]

    public init(client: GatewayWebSocketClient, attachmentPipeline: AttachmentPipeline = .init()) {
        self.client = client
        self.attachmentPipeline = attachmentPipeline
    }

    public func connect() async throws -> HelloOkPayload {
        let hello = try await client.connect()

        await client.setEventHandler { [weak self] frame in
            Task {
                await self?.handle(frame: frame)
            }
        }

        return hello
    }

    public func disconnect() async {
        await client.setEventHandler(nil)
        await client.disconnect()

        for continuation in eventStreams.values {
            continuation.finish()
        }
        eventStreams.removeAll()
    }

    public func streamChatEvents() -> AsyncStream<ChatEventPayload> {
        let id = UUID()
        return AsyncStream { continuation in
            eventStreams[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStream(id: id) }
            }
        }
    }

    public func fetchHistory(sessionKey: String, limit: Int = 100) async throws -> ChatHistoryResponse {
        let payload = try await client.request(
            method: "chat.history",
            params: ChatHistoryParams(sessionKey: sessionKey, limit: limit)
        )
        return try payload.decode(as: ChatHistoryResponse.self)
    }

    @discardableResult
    public func send(
        sessionKey: String,
        text: String,
        attachments: [ChatAttachmentInput] = [],
        thinking: String? = nil,
        timeoutMs: Int? = nil
    ) async throws -> JSONValue {
        let prepared = try await attachmentPipeline.prepare(text: text, inputs: attachments)

        let params = ChatSendParams(
            sessionKey: sessionKey,
            message: prepared.text,
            thinking: thinking,
            deliver: false,
            attachments: prepared.attachments.isEmpty ? nil : prepared.attachments,
            timeoutMs: timeoutMs,
            idempotencyKey: UUID().uuidString
        )

        return try await client.request(method: "chat.send", params: params)
    }

    public func abort(sessionKey: String, runId: String? = nil) async throws {
        _ = try await client.request(method: "chat.abort", params: ChatAbortParams(sessionKey: sessionKey, runId: runId))
    }

    private func handle(frame: GatewayFrame) {
        guard frame.type == "event", frame.event == "chat", let payload = frame.payload else { return }
        guard let chat = try? payload.decode(as: ChatEventPayload.self) else { return }

        for continuation in eventStreams.values {
            continuation.yield(chat)
        }
    }

    private func removeStream(id: UUID) {
        eventStreams.removeValue(forKey: id)
    }
}
