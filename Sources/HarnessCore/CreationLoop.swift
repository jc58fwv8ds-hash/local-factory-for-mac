import Foundation

public enum CreationLoopReviewMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case localOnly
    case chatGPTAssisted

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localOnly: "パターン1：ローカル完結"
        case .chatGPTAssisted: "パターン2：ChatGPT併用"
        }
    }

    public var detail: String {
        switch self {
        case .localOnly:
            "ローカルモデルの成果物をLocal Factoryが検証し、修正案を説明します。"
        case .chatGPTAssisted:
            "検証後に確認済みのレビュー依頼文を通常ChatGPTへ手動で渡します。"
        }
    }
}

public enum CreationLoopPhase: String, Codable, Sendable {
    case awaitingInstruction
    case localModelWorking
    case validating
    case awaitingHarnessReview
    case awaitingExternalReview
    case awaitingUserDecision
    case completed
    case blocked

    public var displayName: String {
        switch self {
        case .awaitingInstruction: "制作指示を待っています"
        case .localModelWorking: "ローカルモデルが提案を準備しています"
        case .validating: "成果物を検査・テスト中です"
        case .awaitingHarnessReview: "Harnessの修正案を確認できます"
        case .awaitingExternalReview: "ChatGPTレビューを準備できます"
        case .awaitingUserDecision: "次の修正指示を待っています"
        case .completed: "制作ループは完了しました"
        case .blocked: "問題を解決してから再開できます"
        }
    }
}

public struct CreationLoopState: Codable, Equatable, Sendable {
    public var reviewMode: CreationLoopReviewMode
    public var phase: CreationLoopPhase
    public var iteration: Int
    public var lastValidationSucceeded: Bool?
    public var updatedAt: Date

    public init(
        reviewMode: CreationLoopReviewMode = .localOnly,
        phase: CreationLoopPhase = .awaitingInstruction,
        iteration: Int = 0,
        lastValidationSucceeded: Bool? = nil,
        updatedAt: Date = .now
    ) {
        self.reviewMode = reviewMode
        self.phase = phase
        self.iteration = max(0, iteration)
        self.lastValidationSucceeded = lastValidationSucceeded
        self.updatedAt = updatedAt
    }
}

public enum CreationLoopWorkflow {
    public static let maximumImportedReviewCharacters = 24_000

    public static func select(
        reviewMode: CreationLoopReviewMode,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        project.creationLoop.reviewMode = reviewMode
        if project.creationLoop.phase == .awaitingExternalReview,
           reviewMode == .localOnly {
            project.creationLoop.phase = .awaitingHarnessReview
        } else if project.creationLoop.phase == .awaitingHarnessReview,
                  reviewMode == .chatGPTAssisted {
            project.creationLoop.phase = .awaitingExternalReview
        }
        project.creationLoop.updatedAt = now
    }

    public static func acceptedInstruction(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        advanceIterationIfNeeded(in: &project)
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        ProjectMilestoneProgress.record(.localWorkStarted, in: &project)
        project.creationLoop.phase = .localModelWorking
        project.creationLoop.updatedAt = now
    }

    public static func acceptedConsultation(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        advanceIterationIfNeeded(in: &project)
        project.creationLoop.phase = .localModelWorking
        project.creationLoop.updatedAt = now
    }

    public static func localProposalReady(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        ProjectMilestoneProgress.record(.proposalReady, in: &project)
        project.creationLoop.phase = .awaitingUserDecision
        project.creationLoop.updatedAt = now
    }

    public static func consultationReady(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        project.creationLoop.phase = .awaitingUserDecision
        project.creationLoop.updatedAt = now
    }

    public static func resumedConsultation(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        project.creationLoop.phase = .localModelWorking
        project.creationLoop.updatedAt = now
    }

    public static func startedValidation(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        ProjectMilestoneProgress.record(.validationStarted, in: &project)
        project.creationLoop.phase = .validating
        project.creationLoop.updatedAt = now
    }

    public static func completedValidation(
        succeeded: Bool,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        ProjectMilestoneProgress.record(
            .validationCompleted(succeeded: succeeded),
            in: &project
        )
        project.creationLoop.lastValidationSucceeded = succeeded
        project.creationLoop.phase = project.creationLoop.reviewMode == .chatGPTAssisted
            ? .awaitingExternalReview
            : .awaitingHarnessReview
        project.creationLoop.updatedAt = now
    }

    public static func importedExternalReview(
        response: String,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let boundedResponse = String(cleaned.prefix(maximumImportedReviewCharacters))
        project.conversation.append(
            ConversationMessage(
                createdAt: now,
                role: .assistant,
                content: boundedResponse,
                modelName: "ChatGPTレビュー",
                origin: .externalReview
            )
        )
        project.activity.insert(
            ActivityEvent(
                occurredAt: now,
                title: "ChatGPTレビューを取り込みました",
                detail: "外部レビューを次の修正指示の参考情報として保存しました",
                kind: .verification
            ),
            at: 0
        )
        project.currentActivity = "レビューを確認し、次の修正指示を入力してください"
        project.creationLoop.phase = .awaitingUserDecision
        project.creationLoop.updatedAt = now
    }

    public static func failed(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        project.creationLoop.phase = .blocked
        project.creationLoop.updatedAt = now
    }

    public static func cancelled(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        project.creationLoop.phase = .awaitingInstruction
        project.creationLoop.updatedAt = now
    }

    @discardableResult
    public static func completed(
        in project: inout HarnessProject,
        now: Date = .now
    ) -> CreationCompletionReadiness {
        let readiness = CreationCompletionPolicy.readiness(for: project)
        guard readiness.isReady else { return readiness }
        ProjectMilestoneProgress.record(.completed, in: &project)
        project.creationLoop.phase = .completed
        project.creationLoop.updatedAt = now
        project.currentActivity = "制作ループを完成として終了しました"
        project.activity.insert(
            ActivityEvent(
                occurredAt: now,
                title: "制作ループを完了しました",
                detail: "\(project.creationLoop.iteration)回の制作サイクルを記録しました",
                kind: .verification
            ),
            at: 0
        )
        return readiness
    }

    private static func advanceIterationIfNeeded(in project: inout HarnessProject) {
        let continuingPhases: Set<CreationLoopPhase> = [
            .awaitingHarnessReview,
            .awaitingExternalReview,
            .awaitingUserDecision,
            .completed,
            .blocked
        ]
        if project.creationLoop.iteration == 0
            || continuingPhases.contains(project.creationLoop.phase) {
            project.creationLoop.iteration += 1
        }
    }
}
