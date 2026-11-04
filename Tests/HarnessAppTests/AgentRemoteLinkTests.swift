import Foundation
import HarnessCore
import Network
import Testing
@testable import HarnessApp

/// The remote link's TLS (2026-11-02): only a device holding a paired key gets through; a line goes both ways.
struct AgentRemoteLinkTests {
    final class Box: @unchecked Sendable { var text = "" }

    func exchange(serverKey: Data, clientKey: Data, id: UUID) async -> String {
        let queue = DispatchQueue(label: "test.agent.tls")
        guard let listener = try? NWListener(using: AgentRemoteLink.tlsParameters(keys: [(id, serverKey)]), on: .any) else { return "listener" }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                connection.send(content: (data ?? Data()) + Data("-ok".utf8), completion: .contentProcessed { _ in })
            }
        }
        let ready = AsyncStream<NWEndpoint.Port?> { continuation in
            listener.stateUpdateHandler = { if case .ready = $0 { continuation.yield(listener.port); continuation.finish() } }
            listener.start(queue: queue)
        }
        var port: NWEndpoint.Port?
        for await p in ready { port = p }
        guard let port else { return "port" }
        let client = NWConnection(host: "127.0.0.1", port: port, using: AgentRemoteLink.tlsParameters(keys: [(id, clientKey)]))
        let box = Box()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = Box()
            let finish: @Sendable (String) -> Void = { text in queue.async { if once.text.isEmpty { once.text = "x"; box.text = text; done.resume() } } }
            client.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    client.send(content: Data("hi".utf8), completion: .contentProcessed { _ in })
                    client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in finish(String(decoding: data ?? Data(), as: UTF8.self)) }
                case .failed, .waiting: finish("failed")
                default: break
                }
            }
            client.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { finish("timeout") }
        }
        client.cancel(); listener.cancel()
        return box.text
    }

    @Test func onlyThePairedKeyGetsThrough() async {
        let id = UUID(), key = Data((0..<32).map { UInt8($0) })
        #expect(await exchange(serverKey: key, clientKey: key, id: id) == "hi-ok")
        let other = Data((0..<32).map { UInt8(255 - $0) })
        #expect(await exchange(serverKey: key, clientKey: other, id: id) != "hi-ok")
    }
}
