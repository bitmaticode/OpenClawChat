import CryptoKit
import Foundation

public struct DeviceIdentity: Sendable {
    public let deviceId: String
    public let publicKeyBase64URL: String
    public let privateKey: Curve25519.Signing.PrivateKey

    public init(deviceId: String, publicKeyBase64URL: String, privateKey: Curve25519.Signing.PrivateKey) {
        self.deviceId = deviceId
        self.publicKeyBase64URL = publicKeyBase64URL
        self.privateKey = privateKey
    }
}

public enum DeviceIdentityStore {
    /// Minimal local store for MVP. For production, move this to Keychain/Secure Enclave.
    public static func loadOrCreate(storageURL: URL) throws -> DeviceIdentity {
        let fm = FileManager.default
        if fm.fileExists(atPath: storageURL.path) {
            let data = try Data(contentsOf: storageURL)
            let record = try JSONDecoder().decode(StoredKey.self, from: data)
            let privateKeyData = Data(base64Encoded: record.privateKeyB64) ?? Data()
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            let pubRaw = privateKey.publicKey.rawRepresentation
            let derivedDeviceId = sha256Hex(pubRaw)
            return DeviceIdentity(
                deviceId: derivedDeviceId,
                publicKeyBase64URL: base64URLEncode(pubRaw),
                privateKey: privateKey
            )
        }

        try fm.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let privateKey = Curve25519.Signing.PrivateKey()
        let pubRaw = privateKey.publicKey.rawRepresentation
        let record = StoredKey(privateKeyB64: privateKey.rawRepresentation.base64EncodedString())
        let encoded = try JSONEncoder().encode(record)
        try encoded.write(to: storageURL, options: [.atomic])

        return DeviceIdentity(
            deviceId: sha256Hex(pubRaw),
            publicKeyBase64URL: base64URLEncode(pubRaw),
            privateKey: privateKey
        )
    }

    private struct StoredKey: Codable {
        let privateKeyB64: String
    }
}

public enum DeviceSignature {
    /// Matches gateway `buildDeviceAuthPayload` format (v2)
    public static func buildPayload(
        deviceId: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int64,
        token: String,
        nonce: String
    ) -> String {
        let scopesCsv = scopes.joined(separator: ",")
        return [
            "v2",
            deviceId,
            clientId,
            clientMode,
            role,
            scopesCsv,
            String(signedAtMs),
            token,
            nonce
        ].joined(separator: "|")
    }

    public static func sign(payload: String, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let signature = try privateKey.signature(for: Data(payload.utf8))
        return base64URLEncode(signature)
    }
}

func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
