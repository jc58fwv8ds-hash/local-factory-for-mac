import HarnessCore
import Testing

/// 2026-11-25 review: a run with old failing tests set aside ended with 「ビルドとテストに合格しました」.
struct RunVerdictTests {
    @Test func aCleanRunSaysItPassed() {
        let verdict = RunVerdict(saved: 2, repairRounds: 1)
        #expect(verdict.isFullPass)
        #expect(verdict.message == "できました。ビルドとテストに合格しました(保存 2 件、修正 1 回)。")
        #expect(RunVerdict(saved: 0, repairRounds: 3, fixedLeftover: true).message.contains("残っていたエラーを直して"))
    }

    @Test func oldFailuresAreToldApartFromThisChange() {
        let verdict = RunVerdict(saved: 1, repairRounds: 0, stillFailingBefore: ["ReadingTests.swift"])
        #expect(!verdict.isFullPass)
        #expect(!verdict.message.contains("ビルドとテストに合格しました"))
        #expect(!verdict.message.hasPrefix("できました"))
        #expect(verdict.message.contains("今回の変更: ビルドは通り、前から通らないテスト以外は通りました"))
        #expect(verdict.message.contains("前からの不合格: ReadingTests.swift"))
        #expect(verdict.message.contains("全部のテストに合格したわけではありません"))
    }

    @Test func uncheckedAndLeftOutStepsAreNamed() {
        let verdict = RunVerdict(saved: 2, repairRounds: 0, leftOut: ["B.swift"], unverified: ["A.swift"])
        #expect(verdict.message.contains("未確認: A.swift"))
        #expect(verdict.message.contains("入れられなかった変更: B.swift"))
        #expect(!verdict.message.contains("合格しました"))
    }
}
