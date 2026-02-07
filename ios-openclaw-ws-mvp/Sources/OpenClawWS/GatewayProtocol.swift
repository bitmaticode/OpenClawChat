import Foundation

public enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct GatewayFrame: Codable, Sendable {
    public let type: String
    public let id: String?
    public let method: String?
    public let event: String?
    public let ok: Bool?
    public let payload: JSONValue?
    public let error: GatewayErrorShape?

    public init(type: String, id: String? = nil, method: String? = nil, event: String? = nil, ok: Bool? = nil, payload: JSONValue? = nil, error: GatewayErrorShape? = nil) {
        self.type = type
        self.id = id
        self.method = method
        self.event = event
        self.ok = ok
        self.payload = payload
        self.error = error
    }
}

public struct GatewayErrorShape: Codable, Sendable, Error {
    public let code: String
    public let message: String
    public let retryable: Bool?
    public let retryAfterMs: Int?
}

public struct ConnectChallengePayload: Codable, Sendable {
    public let nonce: String
    public let ts: Int64
}

public struct ConnectRequestParams: Codable, Sendable {
    public struct ClientInfo: Codable, Sendable {
        public let id: String
        public let displayName: String?
        public let version: String
        public let platform: String
        public let mode: String
        public let instanceId: String?

        public init(id: String = "openclaw-ios", displayName: String? = "OpenClaw iOS", version: String = "0.1.0", platform: String = "ios", mode: String = "ui", instanceId: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.version = version
            self.platform = platform
            self.mode = mode
            self.instanceId = instanceId
        }
    }

    public struct DeviceInfo: Codable, Sendable {
        public let id: String
        public let publicKey: String
        public let signature: String
        public let signedAt: Int64
        public let nonce: String?
    }

    public struct Auth: Codable, Sendable {
        public let token: String?
        public let password: String?
    }

    public let minProtocol: Int
    public let maxProtocol: Int
    public let client: ClientInfo
    public let role: String
    public let scopes: [String]
    public let caps: [String]
    public let commands: [String]
    public let permissions: [String: Bool]
    public let auth: Auth?
    public let locale: String?
    public let userAgent: String?
    public let device: DeviceInfo

    public init(
        minProtocol: Int = 3,
        maxProtocol: Int = 3,
        client: ClientInfo,
        role: String = "operator",
        scopes: [String] = ["operator.read", "operator.write"],
        caps: [String] = ["tool-events"],
        commands: [String] = [],
        permissions: [String: Bool] = [:],
        auth: Auth?,
        locale: String? = nil,
        userAgent: String? = "openclaw-ios/0.1.0",
        device: DeviceInfo
    ) {
        self.minProtocol = minProtocol
        self.maxProtocol = maxProtocol
        self.client = client
        self.role = role
        self.scopes = scopes
        self.caps = caps
        self.commands = commands
        self.permissions = permissions
        self.auth = auth
        self.locale = locale
        self.userAgent = userAgent
        self.device = device
    }
}

public struct HelloOkPayload: Codable, Sendable {
    public struct Server: Codable, Sendable {
        public let version: String
        public let commit: String?
        public let host: String?
        public let connId: String
    }

    public struct Features: Codable, Sendable {
        public let methods: [String]
        public let events: [String]
    }

    public struct Policy: Codable, Sendable {
        public let maxPayload: Int
        public let maxBufferedBytes: Int
        public let tickIntervalMs: Int
    }

    public let type: String
    public let protocolValue: Int
    public let server: Server
    public let features: Features
    public let policy: Policy

    enum CodingKeys: String, CodingKey {
        case type, server, features, policy
        case protocolValue = "protocol"
    }
}

public struct ChatHistoryParams: Codable, Sendable {
    public let sessionKey: String
    public let limit: Int?
}

public struct ChatAttachment: Codable, Sendable {
    public let type: String
    public let mimeType: String
    public let fileName: String?
    public let content: String // base64

    public init(type: String = "image", mimeType: String, fileName: String? = nil, content: String) {
        self.type = type
        self.mimeType = mimeType
        self.fileName = fileName
        self.content = content
    }
}

public struct ChatSendParams: Codable, Sendable {
    public let sessionKey: String
    public let message: String
    public let thinking: String?
    public let deliver: Bool?
    public let attachments: [ChatAttachment]?
    public let timeoutMs: Int?
    public let idempotencyKey: String
}

public struct ChatAbortParams: Codable, Sendable {
    public let sessionKey: String
    public let runId: String?
}

public struct ChatEventPayload: Codable, Sendable {
    public struct ChatMessage: Codable, Sendable {
        public struct ContentBlock: Codable, Sendable {
            public let type: String
            public let text: String?
        }

        public let role: String?
        public let content: [ContentBlock]?
        public let timestamp: Int64?
    }

    public let runId: String
    public let sessionKey: String
    public let seq: Int
    public let state: String // delta|final|aborted|error
    public let message: ChatMessage?
    public let errorMessage: String?
}

public extension JSONValue {
    func decode<T: Decodable>(as type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(T.self, from: data)
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
