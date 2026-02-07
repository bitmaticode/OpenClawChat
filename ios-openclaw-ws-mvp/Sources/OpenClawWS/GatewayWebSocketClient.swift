import Foundation

public actor GatewayWebSocketClient {
    public struct Configuration: Sendable {
        public let url: URL
        public let token: String?
        public let password: String?
        public let clientInfo: ConnectRequestParams.ClientInfo
        public let role: String
        public let scopes: [String]

        public init(
            url: URL,
            token: String?,
            password: String? = nil,
            clientInfo: ConnectRequestParams.ClientInfo = .init(),
            role: String = "operator",
            scopes: [String] = ["operator.read", "operator.write"]
        ) {
            self.url = url
            self.token = token
            self.password = password
            self.clientInfo = clientInfo
            self.role = role
            self.scopes = scopes
        }
    }

    public enum GatewayClientError: Error, LocalizedError {
        case disconnected
        case timeout(String)
        case invalidPayload(String)
        case serverError(String)

        public var errorDescription: String? {
            switch self {
            case .disconnected: return "Gateway disconnected"
            case .timeout(let reason): return "Timeout: \(reason)"
            case .invalidPayload(let reason): return "Invalid payload: \(reason)"
            case .serverError(let reason): return "Gateway error: \(reason)"
            }
        }
    }

    private struct RequestEnvelope<P: Encodable>: Encodable {
        let type: String
        let id: String
        let method: String
        let params: P
    }

    public var onEvent: (@Sendable (GatewayFrame) -> Void)?

    public func setEventHandler(_ handler: (@Sendable (GatewayFrame) -> Void)?) {
        self.onEvent = handler
    }

    private let config: Configuration
    private let identity: DeviceIdentity
    private let session: URLSession

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    private var pendingRequests: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var challengeWaiters: [CheckedContinuation<ConnectChallengePayload, Error>] = []

    public init(configuration: Configuration, identity: DeviceIdentity, session: URLSession = .shared) {
        self.config = configuration
        self.identity = identity
        self.session = session
    }

    deinit {
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    public func connect(timeoutMs: UInt64 = 10_000) async throws -> HelloOkPayload {
        var request = URLRequest(url: config.url)
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000

        let ws = session.webSocketTask(with: request)
        self.socket = ws
        ws.resume()

        receiveTask = Task {
            await self.readLoop()
        }

        let challenge = try await waitForChallenge(timeoutMs: timeoutMs)
        return try await sendConnect(challenge: challenge, timeoutMs: timeoutMs)
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        let requestContinuations = pendingRequests
        pendingRequests.removeAll()
        requestContinuations.values.forEach { $0.resume(throwing: GatewayClientError.disconnected) }

        let challengeContinuations = challengeWaiters
        challengeWaiters.removeAll()
        challengeContinuations.forEach { $0.resume(throwing: GatewayClientError.disconnected) }
    }

    public func request(method: String, params: some Encodable, timeoutMs: UInt64 = 20_000) async throws -> JSONValue {
        guard socket != nil else { throw GatewayClientError.disconnected }

        let requestId = UUID().uuidString

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation

            Task {
                do {
                    try await self.sendFrame(type: "req", id: requestId, method: method, params: params)
                } catch {
                    await self.failPending(id: requestId, error: error)
                }
            }

            if timeoutMs > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                    await self.failPending(id: requestId, error: GatewayClientError.timeout("request \(method)"))
                }
            }
        }
    }

    private func waitForChallenge(timeoutMs: UInt64) async throws -> ConnectChallengePayload {
        try await withCheckedThrowingContinuation { continuation in
            challengeWaiters.append(continuation)

            if timeoutMs > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                    await self.failChallengeWaitersWithTimeoutIfNeeded()
                }
            }
        }
    }

    private func failChallengeWaitersWithTimeoutIfNeeded() {
        guard !challengeWaiters.isEmpty else { return }
        let waiters = challengeWaiters
        challengeWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: GatewayClientError.timeout("connect.challenge")) }
    }

    private func sendConnect(challenge: ConnectChallengePayload, timeoutMs: UInt64) async throws -> HelloOkPayload {
        let signedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let payload = DeviceSignature.buildPayload(
            deviceId: identity.deviceId,
            clientId: config.clientInfo.id,
            clientMode: config.clientInfo.mode,
            role: config.role,
            scopes: config.scopes,
            signedAtMs: signedAt,
            token: config.token ?? "",
            nonce: challenge.nonce
        )

        let signature = try DeviceSignature.sign(payload: payload, privateKey: identity.privateKey)

        let params = ConnectRequestParams(
            minProtocol: 3,
            maxProtocol: 3,
            client: config.clientInfo,
            role: config.role,
            scopes: config.scopes,
            caps: ["tool-events"],
            commands: [],
            permissions: [:],
            auth: .init(token: config.token, password: config.password),
            locale: Locale.current.identifier,
            userAgent: "openclaw-ios/0.1.0",
            device: .init(
                id: identity.deviceId,
                publicKey: identity.publicKeyBase64URL,
                signature: signature,
                signedAt: signedAt,
                nonce: challenge.nonce
            )
        )

        let raw = try await request(method: "connect", params: params, timeoutMs: timeoutMs)
        return try raw.decode(as: HelloOkPayload.self)
    }

    private func sendFrame(type: String, id: String, method: String, params: some Encodable) async throws {
        let envelope = RequestEnvelope(type: type, id: id, method: method, params: params)
        let data = try JSONEncoder().encode(envelope)

        guard let text = String(data: data, encoding: .utf8) else {
            throw GatewayClientError.invalidPayload("UTF8 encoding")
        }

        guard let socket else { throw GatewayClientError.disconnected }
        try await socket.send(.string(text))
    }

    private func readLoop() async {
        guard let socket else { return }

        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let data: Data

                switch message {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let d):
                    data = d
                @unknown default:
                    continue
                }

                let frame = try JSONDecoder().decode(GatewayFrame.self, from: data)
                await handle(frame: frame)
            } catch {
                disconnect()
                return
            }
        }
    }

    private func handle(frame: GatewayFrame) async {
        if frame.type == "event", frame.event == "connect.challenge", let payload = frame.payload {
            do {
                let challenge = try payload.decode(as: ConnectChallengePayload.self)
                let waiters = challengeWaiters
                challengeWaiters.removeAll()
                waiters.forEach { $0.resume(returning: challenge) }
            } catch {
                let waiters = challengeWaiters
                challengeWaiters.removeAll()
                waiters.forEach { $0.resume(throwing: error) }
            }
            return
        }

        if frame.type == "res", let id = frame.id {
            guard let continuation = pendingRequests.removeValue(forKey: id) else { return }

            if frame.ok == true {
                continuation.resume(returning: frame.payload ?? .null)
            } else {
                let message = frame.error?.message ?? "Unknown gateway error"
                continuation.resume(throwing: GatewayClientError.serverError(message))
            }
            return
        }

        onEvent?(frame)
    }

    private func failPending(id: String, error: Error) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }
}
