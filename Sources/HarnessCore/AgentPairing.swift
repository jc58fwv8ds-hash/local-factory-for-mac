import CryptoKit
import Foundation

/// Pairing a device with the agent (2026-11-02), after Casement (casement.win/security, 2026-10-17): no relay and no
/// account; the first connection shows the same 6 digits on the Mac and on the device, and only a device the user allows
/// on the Mac is kept. From then on each device has its own key and every connection proves it (TLS with that key).
///
/// The digits come from an X25519 exchange: both sides hash the shared secret with both public keys. Someone between them
/// would hold two different secrets, so the two screens would show different digits (numeric comparison, as in
/// Bluetooth pairing). The device key is derived from the same secret and never travels over the network.
public struct AgentPairing: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) { self.privateKey = privateKey }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    public struct Result: Equatable, Sendable {
        /// The 6 digits both screens show.
        public let code: String
        /// The device's key for later connections (32 bytes).
        public let deviceKey: Data
    }

    /// `macKey` and `deviceKey` are the two public keys in a fixed order, so both sides hash the same bytes.
    public func complete(peerPublicKey: Data, macKey: Data, deviceKey: Data) throws -> Result {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let transcript = Data("local-factory-agent-pairing-v1".utf8) + macKey + deviceKey
        let check = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("code".utf8), outputByteCount: 8)
        let number = check.withUnsafeBytes { bytes in bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("device-key".utf8), outputByteCount: 32)
        return Result(code: String(format: "%06llu", number % 1_000_000), deviceKey: key.withUnsafeBytes { Data($0) })
    }
}

/// The messages between the agent on the Mac and a device, one JSON object per line.
public enum AgentWire {
    public static let port: UInt16 = 47_820
    public static let bonjourType = "_lfagent._tcp"
    /// The pairing port (port + 1) while it is open.
    public static let pairingBonjourType = "_lfagent-pair._tcp"
    public static let maximumLine = 64 * 1024

    /// Device → Mac.
    public struct Command: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case pair, request, approve, interrupt, history }
        public var kind: Kind
        public var text: String?
        public var id: UUID?
        public var allowed: Bool?
        /// pair: the device's name and public key.
        public var deviceName: String?
        public var publicKey: Data?

        public init(kind: Kind, text: String? = nil, id: UUID? = nil, allowed: Bool? = nil, deviceName: String? = nil, publicKey: Data? = nil) {
            self.kind = kind; self.text = text; self.id = id; self.allowed = allowed; self.deviceName = deviceName; self.publicKey = publicKey
        }

        /// The op for the agent core, or nil for the link's own commands (pair, history).
        public var op: AgentOp? {
            switch kind {
            case .request: text.map { .request($0, .remote) }
            case .approve: id.map { .approve($0, allowed ?? false) }
            case .interrupt: .interrupt
            case .pair, .history: nil
            }
        }
    }

    /// Mac → device.
    public struct Event: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case paired, receipt, entry, history, state }
        public var kind: Kind
        public var text: String?
        public var entries: [AgentEntry]?
        /// pair: the Mac's public key and the device's id for later connections.
        public var publicKey: Data?
        public var deviceID: UUID?
        public var running: Bool?
        public var approvalID: UUID?
        /// state: when the running request should be done, going by earlier ones (the iPhone shows the time left).
        public var expectedEnd: Date?

        public init(kind: Kind, text: String? = nil, entries: [AgentEntry]? = nil, publicKey: Data? = nil, deviceID: UUID? = nil,
                    running: Bool? = nil, approvalID: UUID? = nil, expectedEnd: Date? = nil) {
            self.kind = kind; self.text = text; self.entries = entries; self.publicKey = publicKey; self.deviceID = deviceID
            self.running = running; self.approvalID = approvalID; self.expectedEnd = expectedEnd
        }
    }

    public static func line<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value) + Data([0x0A])
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        guard line.count <= maximumLine else { throw CocoaError(.coderValueNotFound) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: line)
    }
}
