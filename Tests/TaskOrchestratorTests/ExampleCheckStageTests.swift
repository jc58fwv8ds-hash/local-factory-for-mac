import Testing
@testable import TaskOrchestrator

struct ExampleCheckStageTests {
    @Test func examplesAreParsedFromTheModelsBlocks() {
        let response = """
        ### 1
        CASE: 合計がちょうど5000円の注文
        WHAT: 送料(円)
        SETUP: let cart = Cart(total: 5000)
        EXPR: Shipping.fee(for: cart)
        ALT: 5000円ちょうどは対象外にして、5000円を超えたら無料にする
        ALT: 税込みの合計で判定する
        ### 2
        **CASE:** 合計が4999円の注文
        **WHAT:** 送料(円)
        SETUP: なし
        EXPR: `Shipping.fee(for: Cart(total: 4999))`
        ### 3
        CASE: 欠けた例
        """
        let examples = ExampleCheckStage.parse(response)
        #expect(examples.count == 2)   // the third has no WHAT / EXPR
        #expect(examples[0] == .init(situation: "合計がちょうど5000円の注文", quantity: "送料(円)", setup: "let cart = Cart(total: 5000)",
                                     expression: "Shipping.fee(for: cart)",
                                     alternatives: ["5000円ちょうどは対象外にして、5000円を超えたら無料にする", "税込みの合計で判定する"]))
        #expect(examples[1].setup == "" && examples[1].expression == "Shipping.fee(for: Cart(total: 4999))")
    }

    @Test func theTestFilePrintsEachValueAndTheOutputIsReadBack() {
        let file = ExampleCheckStage.testFile([.init(situation: "s", quantity: "q", setup: "", expression: "1 + 1", alternatives: [])],
                                              module: "Shop")
        #expect(file.contains("@testable import Shop") && file.contains("let value: Any = 1 + 1")
                && file.contains(#"print("LF_EXAMPLE_1=" + String(describing: value))"#))
        let output = "◇ Test lfExample1() started.\nLF_EXAMPLE_1=500\nLF_EXAMPLE_2=[5, 4]\nLF_EXAMPLE_3=エラー\n✔ Test lfExample1() passed"
        #expect(ExampleCheckStage.printed(output) == [1: "500", 2: "[5, 4]", 3: "エラー"])
        // A diagnostic quoting the source line is not a value; Optional / nil / quotes read as a person writes them.
        let quoted = "x.swift:9:5: error: ...\n    print(\"LF_EXAMPLE_4=エラー\")\nLF_EXAMPLE_5=Optional(8500)\nLF_EXAMPLE_6=nil\nLF_EXAMPLE_7=\"渋谷\""
        #expect(ExampleCheckStage.printed(quoted) == [5: "8500", 6: "なし", 7: "渋谷"])
    }

    @Test func riskSignalsFollowTheMeasuredThresholds() {
        #expect(RiskSignals.reasons(repaired: false, mandatoryClauses: 3, objective: "送料を無料にして").isEmpty)
        #expect(RiskSignals.reasons(repaired: true, mandatoryClauses: nil, objective: "x").count == 1)
        #expect(RiskSignals.reasons(repaired: false, mandatoryClauses: 9, objective: "x").count == 1)
        #expect(RiskSignals.reasons(repaired: false, mandatoryClauses: nil, objective: "5000円以上、1万円未満、ちょうど、除く").count == 1)
    }
}
