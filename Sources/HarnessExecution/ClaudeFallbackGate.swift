import Foundation

/// A fail-closed preflight for the future live Codex-quota → Claude Pro test.
/// This does not start Claude or claim that a subscription prevents extra usage.
public struct ClaudeFallbackEvidence: Sendable {
    public let codexQuotaExhausted: Bool
    public let claudeAuthMethod: String
    public let claudeSubscription: String
    public let extraUsageOff: Bool
    public let providerOverridesAbsent: Bool
    public let commandCompatible: Bool
    public let taskScopeApproved: Bool
    public let observedAt: Date

    public init(codexQuotaExhausted: Bool, claudeAuthMethod: String,
                claudeSubscription: String, extraUsageOff: Bool,
                providerOverridesAbsent: Bool, commandCompatible: Bool,
                taskScopeApproved: Bool, observedAt: Date) {
        self.codexQuotaExhausted = codexQuotaExhausted
        self.claudeAuthMethod = claudeAuthMethod
        self.claudeSubscription = claudeSubscription
        self.extraUsageOff = extraUsageOff
        self.providerOverridesAbsent = providerOverridesAbsent
        self.commandCompatible = commandCompatible
        self.taskScopeApproved = taskScopeApproved
        self.observedAt = observedAt
    }
}

public enum ClaudeFallbackGate {
    public static func blockingReasons(_ evidence: ClaudeFallbackEvidence, now: Date) -> [String] {
        var reasons: [String] = []
        let age = now.timeIntervalSince(evidence.observedAt)
        if age < 0 || age > 300 { reasons.append("認証・課金・利用枠の観測が古い") }
        if !evidence.codexQuotaExhausted { reasons.append("Codexの利用枠切れを確認していない") }
        if evidence.claudeAuthMethod != "claude.ai" || evidence.claudeSubscription.lowercased() != "pro" {
            reasons.append("Claude Proのサブスクリプション認証を確認できない")
        }
        if !evidence.extraUsageOff { reasons.append("Claudeの追加使用OFFを確認できない") }
        if !evidence.providerOverridesAbsent { reasons.append("API等のprovider上書きがある") }
        if !evidence.commandCompatible { reasons.append("実行コマンドの互換性を確認できない") }
        if !evidence.taskScopeApproved { reasons.append("引き継ぐ作業範囲が確定していない") }
        return reasons
    }
}
