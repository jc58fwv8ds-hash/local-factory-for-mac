import Foundation
import HarnessCore
import Network
import Observation
import Security

/// Asking the agent from a paired device, at home or away (2026-11-02), after Casement: no relay, no account.
/// - Paired devices connect to port 47820 with TLS keyed by their own device key (TLS-PSK). Without a paired key the
///   handshake fails, so nothing else on the network can talk to the agent.
/// - A new device pairs on port 47821, open only for two minutes after the user presses 「iPhone をつなぐ」; both screens
///   show the same 6 digits (AgentPairing) and the user allows it on the Mac.
/// At home the Mac is found by Bonjour; away from home the device uses the Mac's Tailscale address.
@MainActor
@Observable
final class AgentRemoteLink {
    static let shared = AgentRemoteLink(agent: .shared)

    struct Device: Codable, Identifiable, Equatable {
        let id: UUID
        let name: String
        let pairedAt: Date
    }

    struct PendingPairing: Equatable {
        let deviceName: String
        let code: String
    }

    var isEnabled = false
    var devices: [Device] = []
    var pairingOpenUntil: Date?
    var pendingPairing: PendingPairing?
    var connectedCount = 0
    var message = ""

    @ObservationIgnored private let agent: AgentStore
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var pairingListener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: AgentRemoteConnection] = [:]
    @ObservationIgnored private var pairingDecision: ((Bool) -> Void)?
    @ObservationIgnored private let queue = DispatchQueue(label: "local.factory.agent.remote")
    @ObservationIgnored private let devicesFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalFactory/Agent/devices.json")

    init(agent: AgentStore) {
        self.agent = agent
        if let data = try? Data(contentsOf: devicesFile), let saved = try? JSONDecoder().decode([Device].self, from: data) {
            devices = saved.filter { AgentDeviceKeys.key(for: $0.id) != nil }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        enabled ? startListening() : stopAll()
    }

    /// Opens pairing for two minutes.
    func openPairing() {
        guard isEnabled else { return }
        pairingListener?.cancel()
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: AgentWire.port + 1)!)
            listener.service = NWListener.Service(name: Host.current().localizedName, type: AgentWire.pairingBonjourType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, pairing: true) }
            }
            listener.start(queue: queue)
            pairingListener = listener
            let until = Date().addingTimeInterval(120)
            pairingOpenUntil = until
            message = "iPhone の Local Factory Remote から、この Mac を選んでください(2 分間)"
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                if self?.pairingOpenUntil == until { self?.closePairing() }
            }
        } catch {
            message = "つなぐ受付を開けませんでした: \(error.localizedDescription)"
        }
    }

    func closePairing() {
        pairingListener?.cancel()
        pairingListener = nil
        pairingOpenUntil = nil
        decidePairing(false)
    }

    func decidePairing(_ allowed: Bool) {
        pendingPairing = nil
        pairingDecision?(allowed)
        pairingDecision = nil
    }

    func remove(_ device: Device) {
        AgentDeviceKeys.delete(device.id)
        devices.removeAll { $0.id == device.id }
        saveDevices()
        // Connections made with the removed key end now (Casement: removing a pairing cuts it immediately).
        restartListening()
    }

    // MARK: pairing (called by AgentRemoteConnection)

    /// Shows the digits on the Mac and waits for the user's decision; stores the device when allowed.
    func pair(deviceName: String, result: AgentPairing.Result) async -> UUID? {
        guard pairingOpenUntil != nil else { return nil }
        decidePairing(false)
        pendingPairing = PendingPairing(deviceName: deviceName, code: result.code)
        let allowed = await withCheckedContinuation { continuation in
            pairingDecision = { continuation.resume(returning: $0) }
        }
        guard allowed else { return nil }
        let device = Device(id: UUID(), name: String(deviceName.prefix(60)), pairedAt: Date())
        guard AgentDeviceKeys.store(result.deviceKey, for: device.id) else { message = "鍵を保存できませんでした"; return nil }
        devices.append(device)
        saveDevices()
        closePairing()
        message = "「\(device.name)」とつなぎました"
        restartListening()
        return device.id
    }

    func ended(_ connection: AgentRemoteConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connectedCount = connections.values.filter { !$0.isPairing }.count
    }

    // MARK: listening

    private func startListening() {
        listener?.cancel()
        listener = nil
        guard !devices.isEmpty else { message = "「iPhone をつなぐ」で最初の iPhone をつないでください"; return }
        do {
            let listener = try NWListener(using: Self.tlsParameters(keys: devices.compactMap { device in AgentDeviceKeys.key(for: device.id).map { (device.id, $0) } }), on: NWEndpoint.Port(rawValue: AgentWire.port)!)
            listener.service = NWListener.Service(name: Host.current().localizedName, type: AgentWire.bonjourType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, pairing: false) }
            }
            listener.start(queue: queue)
            self.listener = listener
            message = "つないだ iPhone からの依頼を受け付けています"
        } catch {
            message = "受付を開けませんでした: \(error.localizedDescription)"
        }
    }

    private func restartListening() {
        for connection in connections.values where !connection.isPairing { connection.close() }
        if isEnabled { startListening() }
    }

    private func stopAll() {
        listener?.cancel(); listener = nil
        closePairing()
        for connection in connections.values { connection.close() }
        connections = [:]
        connectedCount = 0
        message = ""
    }

    private func accept(_ connection: NWConnection, pairing: Bool) {
        let link = AgentRemoteConnection(connection: connection, isPairing: pairing, link: self, agent: agent, queue: queue)
        connections[ObjectIdentifier(link)] = link
        connectedCount = connections.values.filter { !$0.isPairing }.count
        link.start()
    }

    private func saveDevices() {
        try? FileManager.default.createDirectory(at: devicesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(devices) { try? data.write(to: devicesFile, options: .atomic) }
    }

    /// TLS 1.2 with a pre-shared key per paired device (identity: the device id), as in Apple's Network framework samples.
    /// The device side uses the same with its one key.
    nonisolated static func tlsParameters(keys: [(UUID, Data)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        for (id, key) in keys {
            let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(id.uuidString.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identity as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // Keepalive (2026-11-04): a Wi-Fi link that went quiet while the agent worked is noticed and opened again.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
        return NWParameters(tls: tls, tcp: tcp)
    }
}

/// Device keys in the login keychain, readable by this app only; not synced.
enum AgentDeviceKeys {
    static let service = "local.factory.agent.device"

    static func store(_ key: Data, for id: UUID) -> Bool {
        delete(id)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString, kSecValueData as String: key,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func key(for id: UUID) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    static func delete(_ id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}
