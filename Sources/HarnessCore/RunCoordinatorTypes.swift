import Foundation

public enum RunCoordinatorPhase: String, Codable, Sendable {
    case inactive
    case awaitingChange
    case awaitingValidation
    case awaitingRepair
    case awaitingReview
    case readyForNextItem
    case readyForFinalValidation
    case paused
    case blocked

    public var displayName: String {
        switch self {
        case .inactive: "まだ開始していません"
        case .awaitingChange: "1項目の変更を準備しています"
        case .awaitingValidation: "変更後の検証が必要です"
        case .awaitingRepair: "検証結果の修正が必要です"
        case .awaitingReview: "検証済みの結果を確認できます"
        case .readyForNextItem: "次の1項目へ進めます"
        case .readyForFinalValidation: "全項目の最終検証が必要です"
        case .paused: "連続制作を一時停止しています"
        case .blocked: "同じ失敗を確認してから再開できます"
        }
    }
}

public enum RunCoordinatorStopReason: String, Codable, Sendable {
    case userRequested
    case iterationLimit
    case repeatedFailure
    case operationInProgress
    case workItemUnavailable
}

public enum RunCoordinatorEvent: String, Codable, Sendable {
    case selected
    case changeApplied
    case sourceChanged
    case validationSucceeded
    case validationFailed
    case approved
    case paused
    case blocked
}

public struct RunCoordinatorRecord: Codable, Equatable, Sendable {
    public let sequence: Int
    public let workItemID: UUID
    public let event: RunCoordinatorEvent
    public let occurredAt: Date

    public init(
        sequence: Int,
        workItemID: UUID,
        event: RunCoordinatorEvent,
        occurredAt: Date = .now
    ) {
        self.sequence = max(1, sequence)
        self.workItemID = workItemID
        self.event = event
        self.occurredAt = occurredAt
    }
}

public struct RunCoordinatorState: Codable, Equatable, Sendable {
    public static let defaultMaximumCycles = 6
    public static let maximumAllowedCycles = 12
    public static let maximumRecords = 24

    public var phase: RunCoordinatorPhase
    public var currentWorkItemID: UUID?
    public var attemptedCycleCount: Int
    public var approvedCycleCount: Int
    public var cycleCountSinceConfirmation: Int
    public var maximumCycles: Int
    public var consecutiveMatchingFailures: Int
    public var lastFailureFingerprint: String?
    public var stopReason: RunCoordinatorStopReason?
    public var records: [RunCoordinatorRecord]
    public var updatedAt: Date

    public init(
        phase: RunCoordinatorPhase = .inactive,
        currentWorkItemID: UUID? = nil,
        attemptedCycleCount: Int = 0,
        approvedCycleCount: Int = 0,
        cycleCountSinceConfirmation: Int = 0,
        maximumCycles: Int = defaultMaximumCycles,
        consecutiveMatchingFailures: Int = 0,
        lastFailureFingerprint: String? = nil,
        stopReason: RunCoordinatorStopReason? = nil,
        records: [RunCoordinatorRecord] = [],
        updatedAt: Date = .now
    ) {
        self.phase = phase
        self.currentWorkItemID = currentWorkItemID
        self.attemptedCycleCount = max(0, attemptedCycleCount)
        self.approvedCycleCount = min(max(0, approvedCycleCount), max(0, attemptedCycleCount))
        self.cycleCountSinceConfirmation = max(0, cycleCountSinceConfirmation)
        self.maximumCycles = min(max(1, maximumCycles), Self.maximumAllowedCycles)
        self.consecutiveMatchingFailures = max(0, consecutiveMatchingFailures)
        self.lastFailureFingerprint = lastFailureFingerprint
        self.stopReason = stopReason
        self.records = Array(records.suffix(Self.maximumRecords))
        self.updatedAt = updatedAt
    }

    public var blocksCompletion: Bool {
        phase != .inactive && phase != .readyForFinalValidation
    }
}

extension RunCoordinatorState {
    private enum CodingKeys: String, CodingKey {
        case phase, currentWorkItemID, attemptedCycleCount, approvedCycleCount
        case cycleCountSinceConfirmation, maximumCycles, consecutiveMatchingFailures
        case lastFailureFingerprint
        case stopReason, records, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            phase: try container.decodeIfPresent(
                RunCoordinatorPhase.self,
                forKey: .phase
            ) ?? .inactive,
            currentWorkItemID: try container.decodeIfPresent(
                UUID.self,
                forKey: .currentWorkItemID
            ),
            attemptedCycleCount: try container.decodeIfPresent(
                Int.self,
                forKey: .attemptedCycleCount
            ) ?? 0,
            approvedCycleCount: try container.decodeIfPresent(
                Int.self,
                forKey: .approvedCycleCount
            ) ?? 0,
            cycleCountSinceConfirmation: try container.decodeIfPresent(
                Int.self,
                forKey: .cycleCountSinceConfirmation
            ) ?? 0,
            maximumCycles: try container.decodeIfPresent(
                Int.self,
                forKey: .maximumCycles
            ) ?? Self.defaultMaximumCycles,
            consecutiveMatchingFailures: try container.decodeIfPresent(
                Int.self,
                forKey: .consecutiveMatchingFailures
            ) ?? 0,
            lastFailureFingerprint: try container.decodeIfPresent(
                String.self,
                forKey: .lastFailureFingerprint
            ),
            stopReason: try container.decodeIfPresent(
                RunCoordinatorStopReason.self,
                forKey: .stopReason
            ),
            records: try container.decodeIfPresent(
                [RunCoordinatorRecord].self,
                forKey: .records
            ) ?? [],
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        )
    }
}

public struct RunCoordinatorWorkSelection: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let instruction: String
}

public enum RunCoordinatorBlocker: Equatable, Sendable {
    case operationInProgress
    case reviewRequired
    case validationRequired
    case iterationLimit
    case repeatedFailure
    case workItemUnavailable

    public var guidance: String {
        switch self {
        case .operationInProgress:
            "進行中または中断した作業を先に確認してね。"
        case .reviewRequired:
            "検証済みの結果を確認し、この項目を完了にするか決めてね。"
        case .validationRequired:
            "保存した変更を検証してから次へ進めます。"
        case .iterationLimit:
            "連続制作の上限に達しました。ここまでの結果を確認してね。"
        case .repeatedFailure:
            "同じ種類の検証失敗が続きました。修正方針を確認してから再開してね。"
        case .workItemUnavailable:
            "制作項目が変更または削除されました。計画を確認してね。"
        }
    }
}

public enum RunCoordinatorDecision: Equatable, Sendable {
    case selected(RunCoordinatorWorkSelection)
    case readyForFinalValidation
    case stopped(RunCoordinatorBlocker)
}
