import Foundation

/// Minimal OpenResponses HTTP client for /v1/responses.
/// Used for non-image files (e.g. PDFs) until WS supports generic file attachments.
struct OpenResponsesClient {
    struct ResponseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct RequestBody: Encodable {
        let model: String
        let input: [InputItem]
        let max_output_tokens: Int?
        let stream: Bool?
        let user: String?
    }

    enum InputItem: Encodable {
        case message(role: String, content: [ContentPart])

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .message(let role, let content):
                try container.encode("message", forKey: .type)
                try container.encode(role, forKey: .role)
                try container.encode(content, forKey: .content)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, role, content
        }
    }

    enum ContentPart: Encodable {
        case inputText(String)
        case inputFile(filename: String?, mimeType: String, base64: String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .inputText(let text):
                try container.encode("input_text", forKey: .type)
                try container.encode(text, forKey: .text)

            case .inputFile(let filename, let mimeType, let base64):
                try container.encode("input_file", forKey: .type)
                try container.encode(FileSource(source: .base64(mediaType: mimeType, data: base64, filename: filename)), forKey: .source)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case source
        }
    }

    struct FileSource: Encodable {
        let source: Source

        enum Source: Encodable {
            case base64(mediaType: String, data: String, filename: String?)

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .base64(let mediaType, let data, let filename):
                    try container.encode("base64", forKey: .type)
                    try container.encode(mediaType, forKey: .mediaType)
                    try container.encode(data, forKey: .data)
                    try container.encodeIfPresent(filename, forKey: .filename)
                }
            }

            enum CodingKeys: String, CodingKey {
                case type
                case mediaType = "media_type"
                case data
                case filename
            }
        }
    }

    let baseURL: URL
    let token: String
    let agentId: String

    init(baseURL: URL, token: String, agentId: String = "opus") {
        self.baseURL = baseURL
        self.token = token
        self.agentId = agentId
    }

    /// Returns the assistant text (best-effort extraction).
    func sendPDF(sessionKey: String, prompt: String, pdfData: Data, fileName: String) async throws -> String {
        guard !token.isEmpty else { throw ResponseError(message: "Falta OPENCLAW_GATEWAY_TOKEN") }

        let url = baseURL
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(agentId, forHTTPHeaderField: "x-openclaw-agent-id")
        req.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")

        let b64 = pdfData.base64EncodedString()

        let body = RequestBody(
            model: "openclaw",
            input: [
                .message(
                    role: "user",
                    content: [
                        .inputText(prompt),
                        .inputFile(filename: fileName, mimeType: "application/pdf", base64: b64)
                    ]
                )
            ],
            max_output_tokens: 800,
            stream: false,
            user: nil
        )

        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ResponseError(message: "Respuesta HTTP inválida")
        }

        if !(200...299).contains(http.statusCode) {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ResponseError(message: "HTTP \(http.statusCode): \(raw)")
        }

        return Self.extractAssistantText(from: data) ?? "(sin texto)"
    }

    static func extractAssistantText(from data: Data) -> String? {
        // Best-effort: parse OpenResponses response JSON and join output_text parts.
        guard
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let output = obj["output"] as? [[String: Any]]
        else { return nil }

        var chunks: [String] = []
        for item in output {
            guard item["type"] as? String == "message" else { continue }
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                if part["type"] as? String == "output_text", let t = part["text"] as? String {
                    chunks.append(t)
                }
            }
        }

        let merged = chunks.joined(separator: "")
        return merged.isEmpty ? nil : merged
    }
}
