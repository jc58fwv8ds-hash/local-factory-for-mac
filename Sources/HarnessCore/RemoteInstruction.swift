import Foundation

public struct RemoteInstructionRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let id: UUID
    public let instruction: String
    public let sentAt: Date

    public init(
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

public enum RemoteInstructionStatus: String, Codable, Equatable, Sendable {
    case accepted
    case queued
    case busy
    case unavailable
    case rejected
}

public struct RemoteInstructionDecision: Equatable, Sendable {
    public let status: RemoteInstructionStatus
    public let message: String

    public init(status: RemoteInstructionStatus, message: String) {
        self.status = status
        self.message = String(message.prefix(240))
    }
}

public struct RemoteInstructionReceipt: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let status: RemoteInstructionStatus
    public let message: String
    public let receivedAt: Date

    public init(
        requestID: UUID,
        status: RemoteInstructionStatus,
        message: String,
        receivedAt: Date = .now
    ) {
        self.version = RemoteInstructionRequest.currentVersion
        self.requestID = requestID
        self.status = status
        self.message = String(message.prefix(240))
        self.receivedAt = receivedAt
    }
}

public enum RemoteInstructionBoundaryError: LocalizedError, Equatable, Sendable {
    case payloadTooLarge
    case invalidPayload
    case unsupportedVersion
    case emptyInstruction
    case instructionTooLong
    case invalidCharacters

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            "リモート指示のデータ量が上限を超えています。"
        case .invalidPayload:
            "リモート指示の形式を確認できません。"
        case .unsupportedVersion:
            "リモートアプリとLocal Factoryの通信バージョンが一致しません。"
        case .emptyInstruction:
            "空のリモート指示は受け付けません。"
        case .instructionTooLong:
            "リモート指示は4,000文字以内にしてください。"
        case .invalidCharacters:
            "リモート指示に使用できない制御文字が含まれています。"
        }
    }
}

public enum RemoteInstructionBoundary {
    public static let maximumPayloadBytes = 8_192
    public static let maximumInstructionCharacters = 4_000

    public static func decode(_ data: Data) throws -> RemoteInstructionRequest {
        guard data.count <= maximumPayloadBytes else {
            throw RemoteInstructionBoundaryError.payloadTooLarge
        }
        let decoded: RemoteInstructionRequest
        do {
            decoded = try JSONDecoder().decode(RemoteInstructionRequest.self, from: data)
        } catch {
            throw RemoteInstructionBoundaryError.invalidPayload
        }
        guard decoded.version == RemoteInstructionRequest.currentVersion else {
            throw RemoteInstructionBoundaryError.unsupportedVersion
        }

        let cleaned = decoded.instruction.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleaned.isEmpty else {
            throw RemoteInstructionBoundaryError.emptyInstruction
        }
        guard cleaned.count <= maximumInstructionCharacters else {
            throw RemoteInstructionBoundaryError.instructionTooLong
        }
        guard !cleaned.unicodeScalars.contains(where: { scalar in
            scalar.value == 0
                || (scalar.value < 0x20 && scalar.value != 0x0A && scalar.value != 0x09)
        }) else {
            throw RemoteInstructionBoundaryError.invalidCharacters
        }

        return RemoteInstructionRequest(
            version: decoded.version,
            id: decoded.id,
            instruction: cleaned,
            sentAt: decoded.sentAt
        )
    }

    public static func encode(_ receipt: RemoteInstructionReceipt) throws -> Data {
        try JSONEncoder().encode(receipt)
    }
}

public struct RemotePairingCode: Equatable, Sendable {
    public let value: String

    public init?(_ value: String) {
        guard value.count == 6,
              value.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) else {
            return nil
        }
        self.value = value
    }

    public static func generate(
        using generator: inout some RandomNumberGenerator
    ) -> RemotePairingCode {
        let number = Int.random(in: 0...999_999, using: &generator)
        return RemotePairingCode(String(format: "%06d", number))!
    }
}
