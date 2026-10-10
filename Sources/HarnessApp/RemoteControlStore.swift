import Foundation
import HarnessCore
import Observation

@MainActor
@Observable
final class RemoteControlStore {
    var isEnabled = false
    var pairingCode = ""
    var connectedPeerName: String?
    var statusMessage = "停止中"
    var receivedInstructionCount = 0

    private let transport: RemotePeerTransport
    @ObservationIgnored private var instructionHandler: ((String) -> RemoteInstructionDecision)?
    @ObservationIgnored private var receivedRequestIDs = Set<UUID>()
    @ObservationIgnored private var receivedRequestOrder: [UUID] = []

    init(transport: RemotePeerTransport = RemotePeerTransport()) {
        self.transport = transport
    }

    func configureInstructionHandler(
        _ handler: @escaping (String) -> RemoteInstructionDecision
    ) {
        instructionHandler = handler
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func rotatePairingCode() {
        guard isEnabled else { return }
        start()
    }

    private func start() {
        var generator = SystemRandomNumberGenerator()
        let code = RemotePairingCode.generate(using: &generator)
        pairingCode = code.value
        isEnabled = true
        connectedPeerName = nil
        statusMessage = "iPhoneからの接続を待っています"
        transport.start(pairingCode: code) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    private func stop() {
        transport.stop()
        isEnabled = false
        pairingCode = ""
        connectedPeerName = nil
        statusMessage = "停止中"
        receivedRequestIDs.removeAll()
        receivedRequestOrder.removeAll()
    }

    private func handle(_ event: RemotePeerTransportEvent) {
        switch event {
        case .connected(let peerName):
            connectedPeerName = peerName
            statusMessage = "\(peerName)と暗号化接続しました"
        case .disconnected(let peerName):
            if connectedPeerName == peerName { connectedPeerName = nil }
            statusMessage = "接続が終了しました。再接続を待っています"
        case .failed(let message):
            statusMessage = message
        case .received(let data):
            receive(data)
        }
    }

    private func receive(_ data: Data) {
        do {
            let request = try RemoteInstructionBoundary.decode(data)
            guard !receivedRequestIDs.contains(request.id) else {
                sendReceipt(
                    for: request.id,
                    decision: RemoteInstructionDecision(
                        status: .rejected,
                        message: "同じ指示はすでに受信済みです"
                    )
                )
                return
            }
            remember(request.id)
            let decision = instructionHandler?(request.instruction)
                ?? RemoteInstructionDecision(
                    status: .unavailable,
                    message: "Local Factoryが指示を受け付ける準備を確認できません"
                )
            if decision.status == .accepted || decision.status == .queued {
                receivedInstructionCount += 1
            }
            statusMessage = decision.message
            sendReceipt(for: request.id, decision: decision)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func sendReceipt(
        for requestID: UUID,
        decision: RemoteInstructionDecision
    ) {
        do {
            let receipt = RemoteInstructionReceipt(
                requestID: requestID,
                status: decision.status,
                message: decision.message
            )
            try transport.send(RemoteInstructionBoundary.encode(receipt))
        } catch {
            statusMessage = "受付結果をiPhoneへ返せませんでした：\(error.localizedDescription)"
        }
    }

    private func remember(_ id: UUID) {
        receivedRequestIDs.insert(id)
        receivedRequestOrder.append(id)
        if receivedRequestOrder.count > 100 {
            let removed = receivedRequestOrder.removeFirst()
            receivedRequestIDs.remove(removed)
        }
    }
}
