import Foundation

/// The end of an おまかせ run whose build and checks went through, told in parts (2026-11-25 review): what this run changed,
/// and what was already failing before it and still fails. A run that set old failing tests aside must not end with
/// 「ビルドとテストに合格しました」 as if every test passed, and a change whose step check could not be read is not
/// reported as checked.
public struct RunVerdict: Equatable, Sendable {
    /// Files saved by this run.
    public var saved: Int
    public var repairRounds: Int
    /// Test files that failed before this run, were set aside, and still fail (file names).
    public var stillFailingBefore: [String]
    /// Files of the plan left unchanged because the change would not do what the step asked.
    public var leftOut: [String]
    /// Files saved although the check of their step gave no answer that could be read.
    public var unverified: [String]
    /// 「続けて」 after a run that left only errors: the leftover errors were fixed.
    public var fixedLeftover: Bool

    public init(saved: Int, repairRounds: Int, stillFailingBefore: [String] = [], leftOut: [String] = [],
                unverified: [String] = [], fixedLeftover: Bool = false) {
        self.saved = saved
        self.repairRounds = repairRounds
        self.stillFailingBefore = stillFailingBefore.sorted()
        self.leftOut = leftOut.sorted()
        self.unverified = unverified.sorted()
        self.fixedLeftover = fixedLeftover
    }

    /// Every test passed and every step was checked and went in.
    public var isFullPass: Bool { stillFailingBefore.isEmpty && leftOut.isEmpty && unverified.isEmpty }

    public var message: String {
        let counts = fixedLeftover ? "修正 \(repairRounds) 回" : "保存 \(saved) 件、修正 \(repairRounds) 回"
        if isFullPass {
            return fixedLeftover
                ? "できました。残っていたエラーを直して、ビルドとテストに合格しました(\(counts))。"
                : "できました。ビルドとテストに合格しました(\(counts))。"
        }
        var lines: [String] = []
        let what = fixedLeftover ? "残っていたエラーの直し" : "今回の変更"
        if stillFailingBefore.isEmpty {
            lines.append("\(what): ビルドとテストは通りました(\(counts))。")
        } else {
            lines.append("\(what): ビルドは通り、前から通らないテスト以外は通りました(\(counts))。")
            lines.append("前からの不合格: \(stillFailingBefore.joined(separator: "、")) のテストは、今回の前から通らず、今も通らないままです。"
                + "全部のテストに合格したわけではありません。")
        }
        if !unverified.isEmpty {
            lines.append("未確認: \(unverified.joined(separator: "、")) は、頼まれたとおりの変更かを確かめる返事が読めなかったので、"
                + "確かめられないまま保存しました。")
        }
        if !leftOut.isEmpty {
            lines.append("入れられなかった変更: \(leftOut.joined(separator: "、")) は、書き直しても頼まれたとおりにならなかったので元のままです。"
                + "「続けて」と書けば、そこをもう一度試します。")
        }
        return lines.joined(separator: "\n")
    }
}
