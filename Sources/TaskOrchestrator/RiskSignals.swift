import Foundation

/// 要確認 signals measured on 388 tests-passed runs (2026-10-08; overall false-success rate 22%): repaired before the tests
/// passed 40%, 9+ mandatory clauses 91%, 4+ boundary words 38%, request over 250 characters 38%. Together they mark about a
/// third of the changes and half of the false successes, so the slower checks (examiner, example check) run only there
/// when a manifest asks for gated checks. The app shows the same reasons on the chat card.
package enum RiskSignals {
    static let boundaryWords = ["以上", "以下", "未満", "超", "ちょうど", "含め", "含まない", "除く", "除外", "以外", "前の", "後の",
                                "最低", "最大", "最初", "最後", "境目", "境界"]

    package static func reasons(repaired: Bool, mandatoryClauses: Int?, objective: String) -> [String] {
        var reasons: [String] = []
        if repaired { reasons.append("最初の実装はテストに通らず、修復してから合格しました") }
        if let clauses = mandatoryClauses, clauses >= 9 {
            reasons.append("依頼の条件が多い(\(clauses) 個)。すべて反映されているか確かめてください")
        }
        let boundaries = boundaryWords.reduce(0) { $0 + objective.components(separatedBy: $1).count - 1 }
        if boundaries >= 4 { reasons.append("境界の条件(以上・未満・除くなど)が多い。境目の値を試してください") }
        if objective.count > 250 { reasons.append("依頼文が長い。細かい条件の取りこぼしがないか確かめてください") }
        return reasons
    }
}
