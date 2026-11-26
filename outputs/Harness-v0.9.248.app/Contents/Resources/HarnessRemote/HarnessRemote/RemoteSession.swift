import Foundation
import Observation
import UIKit
@preconcurrency import MultipeerConnectivity

enum RemoteConnectionState: String, CaseIterable, Sendable {
    case idle
    case searching
    case connecting
    case connected
    case failed

    var title: String {
        switch self {
        case .idle: "未接続"
        case .searching: "Harnessを検索中"
        case .connecting: "接続中"
        case .connected: "暗号化接続済み"
        case .failed: "接続を確認してください"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "iphone.radiowaves.left.and.right"
        case .searching: "antenna.radiowaves.left.and.right"
        case .connecting: "ellipsis"
        case .connected: "lock.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
@Observable
final class RemoteSession: NSObject {
    var instruction = ""
    var pairingCode = ""
    var statusMessage = "Mac版Harnessでリモート指示を有効にしてください。"
    var connectedPeerName: String?
    var lastReceipt: RemoteInstructionReceipt?
    var isSending = false
    var state: RemoteConnectionState = .idle

    @ObservationIgnored private let transport: RemoteClientTransport
    @ObservationIgnored private var pendingRequestID: UUID?

    override init() {
        transport = RemoteClientTransport(displayName: UIDevice.current.name)
        super.init()
    }

    var canSend: Bool {
        state == .connected
            && !isSending
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func connect() {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.utf8.count == 6,
              code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            fail("Mac版Harnessに表示された6桁の数字を入力してください。")
            return
        }
        pairingCode = code
        connectedPeerName = nil
        lastReceipt = nil
        pendingRequestID = nil
        isSending = false
        state = .searching
        statusMessage = "近くのHarnessを探しています…"
        transport.start(pairingCode: code) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    func disconnect() {
        transport.stop()
        connectedPeerName = nil
        pendingRequestID = nil
        isSending = false
        state = .idle
        statusMessage = "接続を終了しました。"
    }

    func sendInstruction() {
        guard state == .connected else {
            fail("Harnessへ接続してから送信してください。")
            return
        }
        do {
            let request = try RemoteProtocol.makeRequest(instruction)
            let data = try RemoteProtocol.encodeRequest(request)
            try transport.send(data)
            pendingRequestID = request.id
            isSending = true
            statusMessage = "指示を安全に送信しています…"
        } catch {
            isSending = false
            statusMessage = error.localizedDescription
        }
    }

    private func handle(_ event: RemoteClientEvent) {
        switch event {
        case .searching:
            state = .searching
            statusMessage = "近くのHarnessを探しています…"
        case .connecting(let peerName):
            state = .connecting
            statusMessage = "\(peerName)へ接続しています…"
        case .connected(let peerName):
            state = .connected
            connectedPeerName = peerName
            statusMessage = "\(peerName)と暗号化接続しました。"
        case .disconnected:
            connectedPeerName = nil
            pendingRequestID = nil
            isSending = false
            fail("Harnessとの接続が終了しました。もう一度接続してください。")
        case .failed(let message):
            isSending = false
            fail(message)
        case .received(let data):
            receive(data)
        }
    }

    private func receive(_ data: Data) {
        do {
            let receipt = try RemoteProtocol.decodeReceipt(data)
            guard receipt.requestID == pendingRequestID else {
                statusMessage = "以前の指示に対する応答を受信しました。"
                return
            }
            lastReceipt = receipt
            pendingRequestID = nil
            isSending = false
            statusMessage = receipt.message
            if receipt.status == .accepted || receipt.status == .queued {
                instruction = ""
            }
        } catch {
            isSending = false
            statusMessage = "Harnessの応答を確認できません：\(error.localizedDescription)"
        }
    }

    private func fail(_ message: String) {
        state = .failed
        statusMessage = message
    }
}

private enum RemoteClientEvent: Sendable {
    case searching
    case connecting(String)
    case connected(String)
    case disconnected
    case received(Data)
    case failed(String)
}

private final class RemoteClientTransport: NSObject, @unchecked Sendable {
    private static let serviceType = "harness-remote"

    private let peerID: MCPeerID
    private lazy var session = MCSession(
        peer: peerID,
        securityIdentity: nil,
        encryptionPreference: .required
    )
    private let lock = NSLock()
    private var browser: MCNearbyServiceBrowser?
    private var invitationContext = Data()
    private var invitedPeer: MCPeerID?
    private var eventHandler: (@Sendable (RemoteClientEvent) -> Void)?

    init(displayName: String) {
        let name = String(displayName.prefix(63))
        peerID = MCPeerID(displayName: name.isEmpty ? "Harness Remote" : name)
        super.init()
        session.delegate = self
    }

    func start(
        pairingCode: String,
        eventHandler: @escaping @Sendable (RemoteClientEvent) -> Void
    ) {
        stop()
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        lock.lock()
        invitationContext = Data(pairingCode.utf8)
        invitedPeer = nil
        self.eventHandler = eventHandler
        self.browser = browser
        lock.unlock()
        browser.delegate = self
        browser.startBrowsingForPeers()
        emit(.searching)
    }

    func stop() {
        lock.lock()
        let browser = self.browser
        self.browser = nil
        invitationContext = Data()
        invitedPeer = nil
        eventHandler = nil
        lock.unlock()
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        session.disconnect()
    }

    func send(_ data: Data) throws {
        let peers = session.connectedPeers
        guard !peers.isEmpty else {
            throw RemoteTransportError.notConnected
        }
        try session.send(data, toPeers: peers, with: .reliable)
    }

    private func emit(_ event: RemoteClientEvent) {
        lock.lock()
        let handler = eventHandler
        lock.unlock()
        handler?(event)
    }
}

private enum RemoteTransportError: LocalizedError {
    case notConnected

    var errorDescription: String? { "Harnessとの接続がありません。" }
}

extension RemoteClientTransport: MCNearbyServiceBrowserDelegate {
    func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        lock.lock()
        let canInvite = browser === self.browser
            && invitedPeer == nil
            && info?["protocol"] == "1"
        if canInvite { invitedPeer = peerID }
        let context = invitationContext
        lock.unlock()
        guard canInvite else { return }
        browser.stopBrowsingForPeers()
        emit(.connecting(peerID.displayName))
        browser.invitePeer(
            peerID,
            to: session,
            withContext: context,
            timeout: 20
        )
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        emit(.failed("Harnessの検索を開始できません：\(error.localizedDescription)"))
    }
}

extension RemoteClientTransport: MCSessionDelegate {
    func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        switch state {
        case .connected:
            emit(.connected(peerID.displayName))
        case .connecting:
            emit(.connecting(peerID.displayName))
        case .notConnected:
            emit(.disconnected)
        @unknown default:
            emit(.failed("不明な接続状態です。"))
        }
    }

    func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        emit(.received(data))
    }

    func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}
