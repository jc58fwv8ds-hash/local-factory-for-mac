import Foundation

enum RemoteInstructionStatus: String, Codable, Equatable, Sendable {
    case accepted
    case queued
    case busy
    case unavailable
    case rejected
}

struct RemoteInstructionRequest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let id: UUID
    let instruction: String
    let sentAt: Date

    init(
        version: Int = Self.currentVersion,
        id: UUID = UUID(),
        instruction: String,
        sentAt: Date = .now
    ) {
        self.version = version
        self.id = id
        self.instruction = instruction
        self.sentAt = sentAt
    }
}

struct RemoteInstructionReceipt: Codable, Equatable, Sendable {
    let version: Int
    let requestID: UUID
    let status: RemoteInstructionStatus
    let message: String
    let receivedAt: Date
}

enum RemoteProtocolError: LocalizedError, Equatable, Sendable {
    case payloadTooLarge
    case invalidPayload
    case unsupportedVersion
    case emptyInstruction
    case instructionTooLong
    case invalidCharacters

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            "通信データが8KBの上限を超えています。"
        case .invalidPayload:
            "Harnessからの応答形式を確認できません。"
        case .unsupportedVersion:
            "iPhoneとHarnessの通信バージョンが一致しません。"
        case .emptyInstruction:
            "空の指示は送信できません。"
        case .instructionTooLong:
            "指示は4,000文字以内にしてください。"
        case .invalidCharacters:
            "指示に使用できない制御文字が含まれています。"
        }
    }
}

enum RemoteProtocol {
    static let maximumPayloadBytes = 8_192
    static let maximumInstructionCharacters = 4_000

    static func makeRequest(
        _ rawInstruction: String,
        id: UUID = UUID(),
        sentAt: Date = .now
    ) throws -> RemoteInstructionRequest {
        let instruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { throw RemoteProtocolError.emptyInstruction }
        guard instruction.count <= maximumInstructionCharacters else {
            throw RemoteProtocolError.instructionTooLong
        }
        guard !instruction.unicodeScalars.contains(where: { scalar in
            scalar.value == 0
                || (scalar.value < 0x20 && scalar.value != 0x0A && scalar.value != 0x09)
        }) else {
            throw RemoteProtocolError.invalidCharacters
        }
        return RemoteInstructionRequest(id: id, instruction: instruction, sentAt: sentAt)
    }

    static func encodeRequest(_ request: RemoteInstructionRequest) throws -> Data {
        guard request.version == RemoteInstructionRequest.currentVersion else {
            throw RemoteProtocolError.unsupportedVersion
        }
        let data = try JSONEncoder().encode(request)
        guard data.count <= maximumPayloadBytes else {
            throw RemoteProtocolError.payloadTooLarge
        }
        return data
    }

    static func decodeReceipt(_ data: Data) throws -> RemoteInstructionReceipt {
        guard data.count <= maximumPayloadBytes else {
            throw RemoteProtocolError.payloadTooLarge
        }
        let receipt: RemoteInstructionReceipt
        do {
            receipt = try JSONDecoder().decode(RemoteInstructionReceipt.self, from: data)
        } catch {
            throw RemoteProtocolError.invalidPayload
        }
        guard receipt.version == RemoteInstructionRequest.currentVersion else {
            throw RemoteProtocolError.unsupportedVersion
        }
        return receipt
    }
}
