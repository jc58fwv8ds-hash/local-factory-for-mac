import Foundation

public struct WorkPlanReplanExistingItem: Equatable, Sendable {
    public let reference: String
    public let workItemID: UUID
    public let title: String
    public let detail: String
    public let status: WorkStatus
    public let isPinned: Bool

    public init(
        reference: String,
        workItemID: UUID,
        title: String,
        detail: String,
        status: WorkStatus,
        isPinned: Bool
    ) {
        self.reference = reference
        self.workItemID = workItemID
        self.title = title
        self.detail = detail
        self.status = status
        self.isPinned = isPinned
    }
}

public struct WorkPlanReplanContext: Equatable, Sendable {
    public static let maximumExistingItems = 12

    public let baselineFingerprint: String
    public let items: [WorkPlanReplanExistingItem]
    public let currentState: String
    public let proposedChange: String
    public let expectedResult: String
    public let diagnostics: [String]

    public init(
        baselineFingerprint: String,
        items: [WorkPlanReplanExistingItem],
        currentState: String,
        proposedChange: String,
        expectedResult: String,
        diagnostics: [String]
    ) {
        self.baselineFingerprint = baselineFingerprint
        self.items = items
        self.currentState = currentState
        self.proposedChange = proposedChange
        self.expectedResult = expectedResult
        self.diagnostics = diagnostics
    }

    public var pinnedWorkItemID: UUID? {
        items.first(where: \.isPinned)?.workItemID
    }

    public var availableNewItemCount: Int {
        min(
            WorkPlanReplanProposal.maximumNewItems,
            max(0, Self.maximumExistingItems - items.count)
        )
    }
}

public struct WorkPlanReplanItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let existingWorkItemID: UUID?
    public let title: String
    public let detail: String

    public init(
        id: UUID = UUID(),
        existingWorkItemID: UUID?,
        title: String,
        detail: String
    ) {
        self.id = existingWorkItemID ?? id
        self.existingWorkItemID = existingWorkItemID
        self.title = title
        self.detail = detail
    }

    public var isNew: Bool { existingWorkItemID == nil }
}

public struct WorkPlanReplanProposal: Equatable, Sendable {
    public static let maximumNewItems = 3
    public static let maximumUncertainties = 3
    public static let maximumTitleCharacters = 80
    public static let maximumDetailCharacters = 400
    public static let maximumSummaryCharacters = 400
    public static let maximumUncertaintyCharacters = 200

    public let baselineFingerprint: String
    public let scopedWorkItemIDs: [UUID]
    public let summary: String
    public let uncertainties: [String]
    public let items: [WorkPlanReplanItem]

    public init(
        baselineFingerprint: String,
        scopedWorkItemIDs: [UUID],
        summary: String,
        uncertainties: [String],
        items: [WorkPlanReplanItem]
    ) {
        self.baselineFingerprint = baselineFingerprint
        self.scopedWorkItemIDs = scopedWorkItemIDs
        self.summary = summary
        self.uncertainties = uncertainties
        self.items = items
    }

    public var newItemCount: Int { items.count(where: \.isNew) }
}

public enum WorkPlanReplanError: LocalizedError, Equatable, Sendable {
    case validationSucceeded
    case failureRequiresRecovery
    case noRemainingItems
    case tooManyExistingItems
    case invalidResponse
    case missingExistingItem
    case duplicateReference
    case unknownReference(String)
    case tooManyNewItems
    case tooManyTotalItems
    case invalidTitle
    case invalidDetail
    case invalidSummary
    case invalidUncertainties
    case pinnedItemMoved
    case planChanged

    public var errorDescription: String? {
        switch self {
        case .validationSucceeded: "検証に合格しているため、失敗からの再計画は必要ありません。"
        case .failureRequiresRecovery: "コード修正より先に、開発環境を直して同じ検証をやり直してください。"
        case .noRemainingItems: "見直す未完了項目がありません。"
        case .tooManyExistingItems: "未完了項目が多いため、まず12件以下に整理してください。"
        case .invalidResponse: "AIの再計画案を安全なJSONとして読み取れませんでした。"
        case .missingExistingItem: "既存の未完了項目を残していないため、この案は使えません。"
        case .duplicateReference: "同じ既存項目が再計画案で重複しています。"
        case .unknownReference(let reference): "不明な制作項目が含まれています：\(reference)"
        case .tooManyNewItems: "追加できる新しい制作項目は3件までです。"
        case .tooManyTotalItems: "見直し後の未完了項目は合計12件までです。項目を増やさず整理してください。"
        case .invalidTitle: "再計画案に空または長すぎる項目名があります。"
        case .invalidDetail: "再計画案に長すぎる説明があります。"
        case .invalidSummary: "再計画案の説明が空または長すぎます。"
        case .invalidUncertainties: "未確定点は3件まで、1件200文字以内で示してください。"
        case .pinnedItemMoved: "現在確認中の項目は再計画案の先頭に残してください。"
        case .planChanged: "案を作った後に制作計画が変わりました。新しい状態から案を作り直してね。"
        }
    }
}
