import Foundation
import HarnessCore

enum RemoteInstructionChecks {
    static func run() throws {
        let request = RemoteInstructionRequest(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            instruction: "  設定画面を追加して\nテストも実行して  ",
            sentAt: Date(timeIntervalSince1970: 1_000)
        )
        let decoded = try RemoteInstructionBoundary.decode(
            JSONEncoder().encode(request)
        )
        try expect(
            decoded.id == request.id
                && decoded.instruction == "設定画面を追加して\nテストも実行して",
            "Remote instructions were not decoded and normalized"
        )

        try expectThrows("Empty remote instructions must be rejected") {
            let empty = RemoteInstructionRequest(instruction: "   \n")
            _ = try RemoteInstructionBoundary.decode(JSONEncoder().encode(empty))
        }
        try expectThrows("Oversized remote instructions must be rejected") {
            let large = RemoteInstructionRequest(
                instruction: String(repeating: "a", count: 4_001)
            )
            _ = try RemoteInstructionBoundary.decode(JSONEncoder().encode(large))
        }
        try expectThrows("Unsupported protocol versions must be rejected") {
            let future = RemoteInstructionRequest(version: 99, instruction: "test")
            _ = try RemoteInstructionBoundary.decode(JSONEncoder().encode(future))
        }
        try expectThrows("Control characters must not cross the remote boundary") {
            let control = RemoteInstructionRequest(instruction: "test\u{0000}command")
            _ = try RemoteInstructionBoundary.decode(JSONEncoder().encode(control))
        }
        try expectThrows("Oversized payloads must be rejected before JSON parsing") {
            _ = try RemoteInstructionBoundary.decode(
                Data(repeating: 0x41, count: RemoteInstructionBoundary.maximumPayloadBytes + 1)
            )
        }

        let receipt = RemoteInstructionReceipt(
            requestID: request.id,
            status: .accepted,
            message: String(repeating: "完", count: 300),
            receivedAt: Date(timeIntervalSince1970: 1_001)
        )
        let encodedReceipt = try RemoteInstructionBoundary.encode(receipt)
        let decodedReceipt = try JSONDecoder().decode(
            RemoteInstructionReceipt.self,
            from: encodedReceipt
        )
        try expect(
            decodedReceipt.status == .accepted
                && decodedReceipt.message.count == 240,
            "Remote receipts must stay bounded"
        )

        try expect(RemotePairingCode("012345")?.value == "012345", "Valid pairing code rejected")
        try expect(RemotePairingCode("12345") == nil, "Short pairing code accepted")
        try expect(RemotePairingCode("12345A") == nil, "Non-numeric pairing code accepted")

        try expect(
            RemoteInvitationPolicy.decide(
                isAdvertiserActive: true,
                pairingCodeMatches: true,
                hasConnectedPeer: false
            ) == .accept,
            "A valid first remote invitation was rejected"
        )
        try expect(
            RemoteInvitationPolicy.decide(
                isAdvertiserActive: true,
                pairingCodeMatches: false,
                hasConnectedPeer: false
            ) == .rejectInvalidCode,
            "An invalid pairing code did not produce the security rejection"
        )
        try expect(
            RemoteInvitationPolicy.decide(
                isAdvertiserActive: true,
                pairingCodeMatches: false,
                hasConnectedPeer: true
            ) == .rejectBusy,
            "A second invitation could replace the active connection status"
        )
        try expect(
            RemoteInvitationPolicy.decide(
                isAdvertiserActive: false,
                pairingCodeMatches: true,
                hasConnectedPeer: false
            ) == .rejectInactive,
            "An invitation from a stopped advertiser was accepted"
        )

        var project = HarnessProject.starter
        ProjectInferenceWorkflow.accept(
            instruction: decoded.instruction,
            workItemID: UUID(),
            origin: .remoteUser,
            in: &project
        )
        try expect(
            project.conversation.last?.origin == .remoteUser
                && project.activity.first?.title.contains("iPhone") == true,
            "Remote instruction provenance was lost in project history"
        )

        print("✓ Remote instructions and invitations use bounded, explicit boundaries")
    }
}
