import Foundation
import Testing
@testable import HarnessRemote

@Test func requestRoundTrip() throws {
    let request = try RemoteProtocol.makeRequest(
        "  画面を確認して  ",
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        sentAt: Date(timeIntervalSince1970: 1_000)
    )
    let data = try RemoteProtocol.encodeRequest(request)
    let decoded = try JSONDecoder().decode(RemoteInstructionRequest.self, from: data)
    #expect(decoded == request)
    #expect(decoded.instruction == "画面を確認して")
}

@Test func emptyInstructionIsRejected() {
    #expect(throws: RemoteProtocolError.emptyInstruction) {
        try RemoteProtocol.makeRequest("  \n  ")
    }
}

@Test func longInstructionIsRejected() {
    let instruction = String(repeating: "あ", count: 4_001)
    #expect(throws: RemoteProtocolError.instructionTooLong) {
        try RemoteProtocol.makeRequest(instruction)
    }
}

@Test func unsafeControlCharacterIsRejected() {
    #expect(throws: RemoteProtocolError.invalidCharacters) {
        try RemoteProtocol.makeRequest("設定を\u{0000}変更して")
    }
}

@Test func newlineAndTabRemainAvailable() throws {
    let request = try RemoteProtocol.makeRequest("画面を確認\n\t設定を変更")
    #expect(request.instruction.contains("\n"))
    #expect(request.instruction.contains("\t"))
}

@Test func receiptRoundTripUsesTypedStatus() throws {
    let requestID = UUID()
    let expected = RemoteInstructionReceipt(
        version: 1,
        requestID: requestID,
        status: .accepted,
        message: "制作指示を受け付けました",
        receivedAt: Date(timeIntervalSince1970: 2_000)
    )
    let data = try JSONEncoder().encode(expected)
    #expect(try RemoteProtocol.decodeReceipt(data) == expected)
}

@Test func unsupportedReceiptVersionIsRejected() throws {
    let receipt = RemoteInstructionReceipt(
        version: 99,
        requestID: UUID(),
        status: .rejected,
        message: "version mismatch",
        receivedAt: .now
    )
    let data = try JSONEncoder().encode(receipt)
    #expect(throws: RemoteProtocolError.unsupportedVersion) {
        try RemoteProtocol.decodeReceipt(data)
    }
}

@Test func oversizedReceiptIsRejectedBeforeDecode() {
    let data = Data(repeating: 0, count: RemoteProtocol.maximumPayloadBytes + 1)
    #expect(throws: RemoteProtocolError.payloadTooLarge) {
        try RemoteProtocol.decodeReceipt(data)
    }
}
