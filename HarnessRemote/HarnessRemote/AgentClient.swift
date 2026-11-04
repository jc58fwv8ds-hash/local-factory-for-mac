import CryptoKit
import Foundation
import Network
import Observation
import Security
import UIKit

/// The iPhone side of the agent link (2026-11-02), after Casement: pair once with 6 digits shown on both screens, then
/// connect with this iPhone's own key, at home by Bonjour or away by the Mac's Tailscale address. Nothing in between.
@MainActor
@Observable
final class AgentClient {
    struct SavedMac: Codable, Equatable {
        let deviceID: UUID
        let macName: String
        var awayHost: String
    }

    var saved: SavedMac?
    var pairingMacs: [String] = []
    var pairingCode: String?
    var status = "未接続"
    /// The Mac's last reply to a command (受け付けました …), kept apart from the connection status (2026-11-04: a receipt
    /// overwrote 「切れました」, so a dropped link looked alive).
    var notice = ""
    var isConnected = false
    var entries: [AgentEntry] = []
    var running = false
    var approvalID: UUID?
    /// When the Mac expects the running request to be done.
    var expectedEnd: Date?
    var draft = ""

    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var browsed: [String: NWEndpoint] = [:]
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var pairingKey: Curve25519.KeyAgreement.PrivateKey?
    @ObservationIgnored private var pairingMacName = ""
    @ObservationIgnored private let queue = DispatchQueue(label: "local.factory.remote.agent")
    /// Commands sent while the link was down, sent again once it is back.
    @ObservationIgnored private var pending: [AgentWire.Command] = []
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var retry = 0
    private static let savedKey = "agent.savedMac"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedKey), let mac = try? JSONDecoder().decode(SavedMac.self, from: data),
           Keychain.key(for: mac.deviceID) != nil {
            saved = mac
        }
    }

    // MARK: pairing

    /// Looks for Macs whose 「iPhone をつなぐ」 is open on this network.
    func browseForPairing() {
        browse(type: AgentWire.pairingBonjourType) { [weak self] names in self?.pairingMacs = names }
        status = "Mac で「iPhone をつなぐ」を押してください"
    }

    func pair(with macName: String) {
        guard let endpoint = browsed[macName] else { return }
        pair(endpoint: endpoint, name: macName)
    }

    /// Away from home: the Mac's Tailscale address (its pairing port).
    func pair(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        pair(endpoint: .hostPort(host: .init(trimmed), port: .init(rawValue: AgentWire.port + 1)!), name: trimmed)
    }

    private func pair(endpoint: NWEndpoint, name: String) {
        disconnect(byUser: true)
        let key = Curve25519.KeyAgreement.PrivateKey()
        pairingKey = key
        pairingMacName = name
        open(NWConnection(to: endpoint, using: .tcp)) { [weak self] in
            self?.send(AgentWire.Command(kind: .pair, deviceName: UIDevice.current.name, publicKey: key.publicKey.rawRepresentation))
            self?.status = "Mac とやり取りしています"
        }
    }

    func forget() {
        if let saved { Keychain.delete(saved.deviceID) }
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        saved = nil
        disconnect(byUser: true)
        entries = []
    }

    func setAwayHost(_ host: String) {
        guard var mac = saved else { return }
        mac.awayHost = host.trimmingCharacters(in: .whitespaces)
        store(mac)
    }

    // MARK: the agent

    /// At home the Mac is found by Bonjour and used the moment it appears (2026-11-04: a fixed 3-second wait made every
    /// connection slow); after 3 seconds without it, the away address (Tailscale) is used. A link that drops is opened
    /// again by itself (1, 2, 4 … up to 15 seconds apart) until `disconnect(byUser:)`.
    func connect() {
        guard let saved, Keychain.key(for: saved.deviceID) != nil else { return }
        disconnect()
        wantsConnection = true
        status = "Mac を探しています"
        browse(type: AgentWire.bonjourType) { [weak self] names in
            guard let self, self.connection == nil, names.contains(saved.macName) else { return }
            self.open(to: self.browsed[saved.macName])
        }
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { @MainActor in
                guard let self, self.connection == nil, self.wantsConnection else { return }
                if let home = self.browsed[saved.macName] { self.open(to: home) }
                else if !saved.awayHost.isEmpty { self.open(to: .hostPort(host: .init(saved.awayHost), port: .init(rawValue: AgentWire.port)!)) }
                else { self.status = "Mac が見つかりません(家の外では Tailscale の住所を入れてください)"; self.scheduleRetry() }
            }
        }
    }

    private func open(to endpoint: NWEndpoint?) {
        guard let endpoint, let saved, let key = Keychain.key(for: saved.deviceID) else { return }
        browser?.cancel(); browser = nil
        status = "Mac とつないでいます"
        open(NWConnection(to: endpoint, using: AgentWire.tlsParameters(id: saved.deviceID, key: key))) { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.retry = 0
            self.status = "つながっています(暗号化)"
            let waiting = self.pending; self.pending = []
            for command in waiting { self.send(command) }
        }
    }

    /// Called when the link drops by itself: opens it again after a short wait.
    private func scheduleRetry() {
        guard wantsConnection, saved != nil else { return }
        let delay = min(15.0, pow(2, Double(retry))); retry += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self, self.wantsConnection, self.connection == nil else { return }
                self.connect()
            }
        }
    }

    /// Back from the background: a link iOS cut meanwhile is opened again at once.
    func resume() {
        guard saved != nil, !isConnected else { return }
        retry = 0
        connect()
    }

    func disconnect(byUser: Bool = false) {
        if byUser { wantsConnection = false }
        connection?.cancel(); connection = nil
        browser?.cancel(); browser = nil
        isConnected = false
        buffer = Data()
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(AgentWire.Command(kind: .request, text: text))
        draft = ""
    }

    func approve(_ allowed: Bool) {
        guard let approvalID else { return }
        send(AgentWire.Command(kind: .approve, id: approvalID, allowed: allowed))
    }

    func interrupt() { send(AgentWire.Command(kind: .interrupt)) }

    // MARK: transport

    private func browse(type: String, update: @escaping @MainActor @Sendable ([String]) -> Void) {
        browser?.cancel()
        browsed = [:]
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.browsed = [:]
                for result in results { if case let .service(name, _, _, _) = result.endpoint { self.browsed[name] = result.endpoint } }
                update(self.browsed.keys.sorted())
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func open(_ connection: NWConnection, ready: @escaping @MainActor @Sendable () -> Void) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready: ready(); self.receive(on: connection)
                case .failed(let error):
                    self.status = "つながりませんでした: \(error.localizedDescription)"; self.disconnect(); self.scheduleRetry()
                case .waiting(let error): self.status = "待っています: \(error.localizedDescription)"
                case .cancelled: self.isConnected = false
                default: break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                if let data { self.buffer.append(data) }
                while let end = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer[self.buffer.startIndex..<end]
                    self.buffer.removeSubrange(self.buffer.startIndex...end)
                    if let event = try? AgentWire.decode(AgentWire.Event.self, from: Data(line)) { self.handle(event) }
                }
                if complete || error != nil || self.buffer.count > AgentWire.maximumLine {
                    // The Mac sends the whole conversation again on the next connection, so nothing said meanwhile is lost.
                    self.disconnect(); self.status = "切れました。つなぎ直しています"; self.scheduleRetry(); return
                }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ event: AgentWire.Event) {
        switch event.kind {
        case .receipt:
            if let macKey = event.publicKey, let key = pairingKey, let result = try? AgentWire.pairingResult(privateKey: key, macKey: macKey) {
                pairingCode = result.code
                pairingKey = nil
                pendingDeviceKey = result.deviceKey
            }
            if let text = event.text { if pairingCode != nil || saved == nil { status = text } else { notice = text } }
        case .paired:
            guard let id = event.deviceID, let key = pendingDeviceKey, Keychain.store(key, for: id) else { status = "鍵を保存できませんでした"; return }
            store(SavedMac(deviceID: id, macName: pairingMacName, awayHost: ""))
            pairingCode = nil
            pendingDeviceKey = nil
            status = "つなぎました"
            disconnect()
            connect()
        case .history: entries = event.entries ?? []
        case .entry: entries.append(contentsOf: event.entries ?? [])
        case .state:
            running = event.running ?? false
            approvalID = event.approvalID
            expectedEnd = event.expectedEnd
        }
    }

    @ObservationIgnored private var pendingDeviceKey: Data?

    /// Sends now, or keeps the command for the next connection when the link is down (a request is never dropped).
    private func send(_ command: AgentWire.Command) {
        guard let data = try? AgentWire.line(command) else { return }
        guard let connection, isConnected || command.kind == .pair else {
            pending.append(command); notice = "つなぎ直してから送ります"; resume(); return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self else { return }
                self.pending.append(command); self.disconnect(); self.scheduleRetry()
            }
        })
    }

    private func store(_ mac: SavedMac) {
        saved = mac
        if let data = try? JSONEncoder().encode(mac) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
    }
}

/// This iPhone's key for the Mac: in the keychain, this device only (not in iCloud or backups).
enum Keychain {
    static let service = "local.factory.remote.agent"

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
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: id.uuidString] as CFDictionary)
    }
}
