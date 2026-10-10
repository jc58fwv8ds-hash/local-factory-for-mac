import Testing
@testable import TaskOrchestrator

struct BatchExaminerStageTests {
    let tests = "import Testing\n@Test func examiner_a() {\n    #expect(1 == 1)\n}\n\n@Test func examiner_b() {\n    broken()\n}\n@Test func examiner_c() { #expect(true) }\n"

    @Test func onlyTheTestFunctionWithACompileErrorIsDropped() {
        let (kept, removed) = BatchExaminerStage.prune(tests, errorLines: [7])
        #expect(removed == ["examiner_b"])
        #expect(kept.contains("examiner_a") && kept.contains("examiner_c") && !kept.contains("broken"))
        #expect(BatchExaminerStage.prune(tests, errorLines: [1]).1.isEmpty)   // an error outside any test removes nothing
    }

    @Test func testBodyAndFailureDetailAreExtractedByName() {
        #expect(BatchExaminerStage.testBody("examiner_b", in: tests) == "@Test func examiner_b() {\n    broken()\n}")
        let output = "◇ Test examiner_a() started.\n✘ Test examiner_a() recorded an issue at X.swift:3:5: Expectation failed: 1 == 2\n↳ 1 → 1\n"
        #expect(BatchExaminerStage.failureDetail("examiner_a", in: output).contains("Expectation failed: 1 == 2"))
    }

    @Test func privateTopLevelHelpersOfVisibleTestsAreOpenedButNestedOnesStay() {
        let source = "private func loc(_ s: String) -> Int { 1 }\nfileprivate let sample = 2\nprivate struct Fixture {\n    private var x = 1\n}\n"
        #expect(BatchExaminerStage.openingPrivateHelpers(source)
                == "func loc(_ s: String) -> Int { 1 }\nlet sample = 2\nstruct Fixture {\n    private var x = 1\n}\n")
    }

    @Test func helpersTheExaminerRedefinesStayPrivate() {
        let visible = "private func loc(_ s: String) -> Int { 1 }\nprivate let sample = 2\n"
        let examiner = "import Testing\nprivate func loc(_ s: String) -> Int { 2 }\n@Test func examiner_a() { #expect(sample == 2) }\n"
        #expect(BatchExaminerStage.topLevelNames(examiner) == ["loc"])
        #expect(BatchExaminerStage.openingPrivateHelpers(visible, except: BatchExaminerStage.topLevelNames(examiner))
                == "private func loc(_ s: String) -> Int { 1 }\nlet sample = 2\n")
    }

    @Test func onlyTestFunctionsArePrefixedSoHelperCallsStillResolve() {
        let source = "private func makeClaim(_ m: Int) -> Int { m }\n@Test func threeHits() { #expect(makeClaim(1) == 1) }\n@Test(\"named\")\nfunc window() {}\n"
        #expect(BatchExaminerStage.prefixingTestFunctions(source)
                == "private func makeClaim(_ m: Int) -> Int { m }\n@Test func examiner_threeHits() { #expect(makeClaim(1) == 1) }\n@Test(\"named\")\nfunc examiner_window() {}\n")
    }

    /// Blind recomputation (2026-10-09): the failed expectation is read from the real Swift Testing output (c2-19, c1-02).
    @Test func expectationFailuresGiveTheExpressionTheExpectedAndTheActualValue() {
        let output = """
        ◇ Test examiner_minutes() started.
        ✘ Test examiner_minutes() recorded an issue at ExaminerScenarioTests.swift:9:5: Expectation failed: scheduler.minutes(for: turf, weather: withRain) == 12
        ↳ scheduler.minutes(for: turf, weather: withRain) == 12 → false
        ↳   scheduler.minutes(for: turf, weather: withRain) → 8
        ✘ Test examiner_csv() recorded an issue at ExaminerScenarioTests.swift:3:5: Expectation failed: try PriceListCSV.fields(of: "a", separator: ";") == ["a"]
        ↳ try PriceListCSV.fields(of: "a", separator: ";") == ["a"] → <not evaluated>
        Caught error: .unterminatedQuote(field: 0)
        """
        #expect(BatchExaminerStage.expectationFailures(of: "examiner_minutes", in: output)
            == [.init(expression: "scheduler.minutes(for: turf, weather: withRain)", expected: "12", actual: "8")])
        #expect(BatchExaminerStage.expectationFailures(of: "examiner_csv", in: output).first?.actual == "throws")
    }

    @Test func expectedValuesAreHiddenAndTheVerdictComesFromTheBlindValue() {
        let body = "@Test func examiner_x() {\n    let p = f()\n    #expect(p.gross == [50, 49])\n    #expect(try g(1) == 5)\n}"
        #expect(BatchExaminerStage.maskingExpectations(body)
            == "@Test func examiner_x() {\n    let p = f()\n    #expect(p.gross == <hidden>)\n    #expect(try g(1) == <hidden>)\n}")
        #expect(BatchExaminerStage.blindVerdict(value: "12", expected: "12", actual: "8") == "code_wrong")
        #expect(BatchExaminerStage.blindVerdict(value: "8", expected: "12", actual: "8") == "test_wrong")
        #expect(BatchExaminerStage.blindVerdict(value: "10", expected: "12", actual: "8") == "unclear")
        #expect(BatchExaminerStage.blindVerdict(value: "", expected: "12", actual: "8") == "unclear")
        #expect(BatchExaminerStage.blindVerdict(value: #"[ "a" ]"#, expected: ##"[#"a"#]"##, actual: "[]") == "code_wrong")
        #expect(BatchExaminerStage.blindVerdict(value: "5000", expected: "5_000", actual: "2500") == "code_wrong")
        #expect(BatchExaminerStage.blindVerdict(value: "9900", expected: "9_900 }", actual: "throws") == "code_wrong")
    }

    @Test func theCautionNamesTheSituationInWordsWithTheMeasuredValues() {
        let failure = BatchExaminerStage.ExpectationFailure(expression: "payouts.map(\\.withholding)", expected: "[5, 4]", actual: "[5, 5]")
        let answer = "...\nCASE: 売上99円をAとBで半分ずつ分ける。\nWHAT: 各人の源泉徴収額\nVALUE: [5, 4]"
        #expect(BatchExaminerStage.plainExample(answer: answer, failure: failure)
            == "売上99円をAとBで半分ずつ分ける → 各人の源泉徴収額が、依頼から計算すると「[5, 4]」、今回の修正では「[5, 5]」")
        // Without the model's words (or with code in them) the expression is shown.
        #expect(BatchExaminerStage.plainExample(answer: "VALUE: [5, 4]", failure: failure).hasPrefix("payouts.map"))
        #expect(BatchExaminerStage.plainExample(answer: "CASE: split(99)\nWHAT: x\nVALUE: 1", failure: failure).hasPrefix("payouts.map"))
    }

    /// The compact format (2026-10-10): values first, rules as properties, `result` under expect: read as a rule.
    @Test func compactBlocksBecomeSwiftTestsWithTheirKinds() {
        let response = """
        ### graceBoundary
        aspect: a
        setup: let calc = FeeCalculator()
        call: calc.fee(forMinutes: 30)
        expect: 0
        ### noNegative
        call: calc.fee(forMinutes: -1)
        expect: result >= 0
        rule: 料金はマイナスにならない
        ### rejectsEmpty
        call: try Parser.parse("")
        throws: yes
        ### broken
        aspect: a
        """
        let (source, kinds, rules) = BatchExaminerStage.compactTests(response, module: "Parking")
        #expect(kinds == ["examiner_graceBoundary": "expect", "examiner_noNegative": "property", "examiner_rejectsEmpty": "throws"])
        #expect(rules == ["examiner_noNegative": "料金はマイナスにならない"])
        #expect(source.contains("@testable import Parking"))
        #expect(source.contains("    let calc = FeeCalculator()\n    let observed = try (calc.fee(forMinutes: 30))\n    #expect(observed == 0)"))
        #expect(source.contains("#expect(throws: (any Error).self) { _ = try try Parser.parse(\"\") }") || source.contains("_ = try Parser"))
        #expect(BatchExaminerStage.blindVerdict(value: "1", expected: "(1)", actual: "0") == "code_wrong")
        #expect(BatchExaminerStage.compactAspects(response) == ["examiner_graceBoundary": "a", "examiner_broken": "a"])
    }
}
