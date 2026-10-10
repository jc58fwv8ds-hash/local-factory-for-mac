import Foundation
import HarnessCore
import MultipeerConnectivity

enum RemotePeerTransportEvent: Sendable {
    case connected(String)
    case disconnected(String)
    case received(Data)
    case failed(String)
}

final class RemotePeerTransport: NSObject, @unchecked Sendable {
    private static let serviceType = "harness-remote"

    private let peerID = MCPeerID(displayName: Host.current().localizedName ?? "Local Factory Mac")
    private lazy var session = MCSession(
        peer: peerID,
        securityIdentity: nil,
        encryptionPreference: .required
    )
    private let lock = NSLock()
    private var advertiser: MCNearbyServiceAdvertiser?
    private var expectedPairingCode = ""
    private var eventHandler: (@Sendable (RemotePeerTransportEvent) -> Void)?

    override init() {
        super.init()
        session.delegate = self
    }

    func start(
        pairingCode: RemotePairingCode,
        eventHandler: @escaping @Sendable (RemotePeerTransportEvent) -> Void
    ) {
        stop()
        lock.lock()
        expectedPairingCode = pairingCode.value
        self.eventHandler = eventHandler
        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["protocol": "1"],
            serviceType: Self.serviceType
        )
        self.advertiser = advertiser
        lock.unlock()
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
    }

    func stop() {
        lock.lock()
        let advertiser = self.advertiser
        self.advertiser = nil
        expectedPairingCode = ""
        eventHandler = nil
        lock.unlock()
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        session.disconnect()
    }

    func send(_ data: Data) throws {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        try session.send(data, toPeers: peers, with: .reliable)
    }

    private func emit(_ event: RemotePeerTransportEvent) {
        lock.lock()
        let handler = eventHandler
        lock.unlock()
        handler?(event)
    }
}

extension RemotePeerTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        emit(.failed(error.localizedDescription))
    }

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let suppliedCode = context.flatMap { String(data: $0, encoding: .utf8) }
        lock.lock()
        let isCurrentAdvertiser = advertiser === self.advertiser
        let hasConnectedPeer = !session.connectedPeers.isEmpty
        let pairingCodeMatches = suppliedCode == expectedPairingCode
        let outcome = RemoteInvitationPolicy.decide(
            isAdvertiserActive: isCurrentAdvertiser,
            pairingCodeMatches: pairingCodeMatches,
            hasConnectedPeer: hasConnectedPeer
        )
        lock.unlock()
        invitationHandler(
            outcome.acceptsConnection,
            outcome.acceptsConnection ? session : nil
        )

        // A second invitation must not replace the healthy connection status with
        // an unrelated error. Only report an invalid code while still available.
        if outcome.reportsInvalidCode {
            emit(.failed("ペアリングコードが一致しない接続を拒否しました"))
        }
    }
}

extension RemotePeerTransport: MCSessionDelegate {
    func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        switch state {
        case .connected:
            emit(.connected(peerID.displayName))
        case .notConnected:
            emit(.disconnected(peerID.displayName))
        case .connecting:
            break
        @unknown default:
            emit(.failed("不明なリモート接続状態です"))
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
