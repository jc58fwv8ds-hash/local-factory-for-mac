import CryptoKit
import Foundation
import Network

/// The agent link's messages and pairing, the same as the Mac's (Sources/HarnessCore/AgentProtocol.swift and
/// AgentPairing.swift, 2026-11-02). Keep the two in step: the Mac decodes exactly these fields.
struct AgentEntry: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case request, step, approval, question, outcome }
    enum Source: String, Codable, Sendable { case mac, remote }
    let id: UUID
    let kind: Kind
    let text: String
    let detail: String
    let source: Source
    let date: Date
}

enum AgentWire {
    static let port: UInt16 = 47_820
    static let bonjourType = "_lfagent._tcp"
    static let pairingBonjourType = "_lfagent-pair._tcp"
    static let maximumLine = 64 * 1024

    struct Command: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case pair, request, approve, interrupt, history }
        var kind: Kind
        var text: String?
        var id: UUID?
        var allowed: Bool?
        var deviceName: String?
        var publicKey: Data?
    }

    struct Event: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case paired, receipt, entry, history, state }
        var kind: Kind
        var text: String?
        var entries: [AgentEntry]?
        var publicKey: Data?
        var deviceID: UUID?
        var running: Bool?
        var approvalID: UUID?
        var expectedEnd: Date?
    }

    static func line<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value) + Data([0x0A])
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: line)
    }

    /// X25519, then 6 digits and the device key from the shared secret and both public keys (Mac's first).
    static func pairingResult(privateKey: Curve25519.KeyAgreement.PrivateKey, macKey: Data) throws -> (code: String, deviceKey: Data) {
        let deviceKey = privateKey.publicKey.rawRepresentation
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: macKey))
        let transcript = Data("local-factory-agent-pairing-v1".utf8) + macKey + deviceKey
        let check = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("code".utf8), outputByteCount: 8)
        let number = check.withUnsafeBytes { bytes in bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript, sharedInfo: Data("device-key".utf8), outputByteCount: 32)
        return (String(format: "%06llu", number % 1_000_000), key.withUnsafeBytes { Data($0) })
    }

    /// TLS 1.2 with the device's key, as the Mac's listener expects.
    static func tlsParameters(id: UUID, key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(id.uuidString.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // Keepalive (2026-11-04): a Wi-Fi link that went quiet while the agent worked is noticed and opened again.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
        return NWParameters(tls: tls, tcp: tcp)
    }
}
