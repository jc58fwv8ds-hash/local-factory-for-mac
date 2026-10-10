import Foundation
import HarnessKernel

public struct DogfoodShadowInput: Codable, Sendable {
    public let taskID: String
    public let objective: String
    public let repositoryPaths: [String]
    public let localModelCompatible: Bool
    public let externalReadiness: ExternalDispatchReadiness
    public let solAvailable: Bool
    public let astraAvailable: Bool

    public init(taskID: String, objective: String, repositoryPaths: [String],
                localModelCompatible: Bool, externalReadiness: ExternalDispatchReadiness,
                solAvailable: Bool, astraAvailable: Bool) {
        self.taskID = taskID
        self.objective = objective
        self.repositoryPaths = repositoryPaths
        self.localModelCompatible = localModelCompatible
        self.externalReadiness = externalReadiness
        self.solAvailable = solAvailable
        self.astraAvailable = astraAvailable
    }
}

public struct DogfoodShadowResult: Codable, Sendable {
    public let schemaVersion: Int
    public let taskID: String
    public let objective: String
    public let phase: String
    public let selectedFiles: [String]
    public let selectedTests: [String]
    public let workClassification: KernelRoutingPolicy.Work
    public let route: KernelRoutingPolicy.Decision
    public let plan: [String]
    public let completionCriteria: [String]
    public let risks: [String]
    public let rollbackPoint: String
    public let externalModelCalls: Int
    public let repositoryWrites: Int
}

/// Read-only D0 policy. Context selection cannot authorize a canary.
public enum DogfoodShadowPlanner {
    public enum Failure: Error { case invalidInput }

    public static func plan(_ input: DogfoodShadowInput,
                            evidence: [ContextFileEvidence] = []) throws -> DogfoodShadowResult {
        let request = input.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.taskID.isEmpty, !request.isEmpty, request.utf8.count <= 8_000,
              input.repositoryPaths.count <= 20_000,
              input.repositoryPaths.allSatisfy(isSafeRelativePath) else { throw Failure.invalidInput }

        let text = request.lowercased()
        let isTransfer = containsAny(text, ["転送", "同期", "接続", "nearby", "transport"])
        let isUI = containsAny(text, ["表示", "画面", "ui", "案内", "ラベル"])
        let isDocs = containsAny(text, ["文書", "説明書", "readme", "ドキュメント"])
        let isPresentationOnly = isUI && containsAny(text, ["中身は変えない", "表示だけ", "文言だけ"])
        let isHighRisk = containsAny(text, ["権限", "セキュリティ", "署名", "課金", "削除", "security", "permission"])
        let isCrossBoundary = !isPresentationOnly && isTransfer && containsAny(text, ["watch", "iphone", "mac"])
        let work: KernelRoutingPolicy.Work = isCrossBoundary || isHighRisk ? .crossBoundary
            : isDocs ? .simpleAnalysis : .focusedEdit
        let decision = KernelRoutingPolicy.decide(work: work,
            localCompatible: input.localModelCompatible,
            subscriptionDispatchVerified: input.externalReadiness.canPrepareExternalDispatch,
            solAvailable: input.solAvailable, astraAvailable: input.astraAvailable,
            materialRisk: isHighRisk)

        let selection = ContextSelector.select(objective: request,
            paths: input.repositoryPaths, evidence: evidence)
        let selected = selection.files
        let tests = selection.tests
        var risks = [String]()
        if selected.isEmpty { risks.append("関連ファイルを特定できていません。人による範囲確認が必要です。") }
        if decision.route == .blocked { risks.append("利用可能な作業モデルを検証できていません。実行は止めます。") }
        if isTransfer { risks.append("実機の送受信はビルドやUnit Testだけでは確認できません。") }
        if isHighRisk { risks.append("権限・安全境界の変更には独立した確認が必要です。") }

        return DogfoodShadowResult(schemaVersion: 1, taskID: input.taskID,
            objective: request, phase: "D0-shadow", selectedFiles: selected,
            selectedTests: tests, workClassification: work, route: decision,
            plan: ["要求と完了条件を確定する", "候補ファイルの現状を読む", "隔離したCandidateで変更案を作る",
                   "関連するビルドとテストで確かめる", "Stable側の独立検証で差分を確認する"],
            completionCriteria: ["要求を満たす", "関連ビルドとテストが通る", "無関係な変更とテスト弱体化がない",
                                 "戻せる差分である"], risks: risks,
            rollbackPoint: "Candidate作業前のGit HEADとsource checkpoint",
            externalModelCalls: 0, repositoryWrites: 0)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
            && !path.contains("\\")
    }

    private static func containsAny(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0) }
    }

}
