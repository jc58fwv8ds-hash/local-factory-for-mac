import Foundation
import HarnessCore
import Network

/// One device's connection to the agent (AgentRemoteLink): JSON lines both ways (AgentWire).
/// A pairing connection exchanges public keys and waits for the user's decision on the Mac; a paired connection (already
/// proven by TLS with the device key) passes the device's ops to the agent and sends every new entry back.
@MainActor
final class AgentRemoteConnection {
    let isPairing: Bool
    private let connection: NWConnection
    private weak var link: AgentRemoteLink?
    private let agent: AgentStore
    private let queue: DispatchQueue
    private var buffer = Data()
    private var listener: UUID?
    private var closed = false

    init(connection: NWConnection, isPairing: Bool, link: AgentRemoteLink, agent: AgentStore, queue: DispatchQueue) {
        self.connection = connection; self.isPairing = isPairing; self.link = link; self.agent = agent; self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.ready()
                case .failed(let error): AgentRemoteConnection.log("切れた: \(error)"); self?.close()
                case .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let listener { agent.stopListening(listener) }
        connection.cancel()
        link?.ended(self)
    }

    private func ready() {
        Self.log(isPairing ? "ペアリングの接続" : "つながった")
        if !isPairing {
            // The model cannot be chosen from the iPhone (2026-11-04, the user: load it by yourself when needed): the agent's
            // 27B is loaded as soon as a device connects, under a lease like any request, so the first request does not wait.
            Task.detached {
                let model = await AgentStore.agentModel
                let request = InferenceRequest(runtime: model.runtime, modelIdentifier: model.identifier, messages: [])
                guard let target = ModelRuntimes.target(for: request),
                      let lease = try? await ModelRuntimes.shared.acquire(target) else { return }
                try? await ModelRuntimes.Backburner().start(model: target.model)
                await ModelRuntimes.shared.release(lease)
            }
            send(AgentWire.Event(kind: .history, entries: Array(agent.entries.suffix(60))))
            sendState()
            listener = agent.listen { [weak self] entry in
                self?.send(AgentWire.Event(kind: .entry, entries: [entry]))
                self?.sendState()
            }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                while let end = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer[self.buffer.startIndex..<end]
                    self.buffer.removeSubrange(self.buffer.startIndex...end)
                    await self.handle(Data(line))
                }
                if self.buffer.count > AgentWire.maximumLine || complete || error != nil {
                    AgentRemoteConnection.log("受信の終わり: complete=\(complete) error=\(String(describing: error)) buffer=\(self.buffer.count)")
                    self.close(); return
                }
                self.receive()
            }
        }
    }

    private func handle(_ line: Data) async {
        guard let command = try? AgentWire.decode(AgentWire.Command.self, from: line) else {
            send(AgentWire.Event(kind: .receipt, text: "読めない命令でした")); return
        }
        if isPairing {
            await pair(command)
        } else if let op = command.op {
            send(AgentWire.Event(kind: .receipt, text: agent.handle(op)))
            sendState()
        } else if command.kind == .history {
            send(AgentWire.Event(kind: .history, entries: Array(agent.entries.suffix(60))))
        }
    }

    private func pair(_ command: AgentWire.Command) async {
        guard command.kind == .pair, let devicePublicKey = command.publicKey, let link else { close(); return }
        let pairing = AgentPairing()
        guard let result = try? pairing.complete(peerPublicKey: devicePublicKey, macKey: pairing.publicKey, deviceKey: devicePublicKey) else {
            close(); return
        }
        // The device computes the same digits from this key and shows them; the user compares the two screens.
        send(AgentWire.Event(kind: .receipt, text: "Mac に出ている 6 桁と同じか確かめてください", publicKey: pairing.publicKey))
        if let id = await link.pair(deviceName: command.deviceName ?? "iPhone", result: result) {
            send(AgentWire.Event(kind: .paired, text: "つなぎました", deviceID: id))
        } else {
            send(AgentWire.Event(kind: .receipt, text: "Mac で断られたか、時間切れです"))
        }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in Task { @MainActor in self?.close() } }
    }

    private func sendState() {
        send(AgentWire.Event(kind: .state, running: agent.isRunning, approvalID: agent.pendingApproval?.id, expectedEnd: agent.expectedEnd))
    }

    private func send(_ event: AgentWire.Event) {
        guard !closed, let data = try? AgentWire.line(event) else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { AgentRemoteConnection.log("送れなかった(\(event.kind)): \(error)") }
        })
    }

    /// Why a device's link ended, for finding out why answers did not reach the iPhone (2026-11-04).
    nonisolated static func log(_ line: String) {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Harness/agent-remote.log")
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(Data(stamped.utf8)); try? handle.close() }
        else { try? stamped.write(to: file, atomically: true, encoding: .utf8) }
    }
}
