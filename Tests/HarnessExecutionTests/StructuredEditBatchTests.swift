import Foundation
import HarnessCore
import HarnessExecution
import Testing

struct StructuredEditBatchTests {
    private func batch(_ edits: [[String: String]]) throws -> StructuredEditBatch {
        try JSONDecoder().decode(StructuredEditBatch.self, from: JSONSerialization.data(withJSONObject: ["edits": edits]))
    }
    private func replace(_ file: String, _ old: String, _ new: String) -> [String: String] {
        ["operation": "replace_exact", "file": file, "expected_old_text": old, "new_text": new]
    }
    @Test func relatedEditsAndTwoFiles() throws {
        let b = try batch([replace("A.swift", "one", "two"), replace("A.swift", "old", "new"), replace("B.swift", "no", "yes")])
        let result = try b.proposedContents(originals: ["A.swift": "one old", "B.swift": "no"], protected: [], appendOnly: [], maxEdits: 3, maxLines: 6)
        #expect(result == ["A.swift": "two new", "B.swift": "yes"])
    }
    @Test func invalidLastEditRejectsWholeBatch() throws {
        let b = try batch([replace("A.swift", "one", "two"), replace("../secret", "no", "yes")])
        #expect(throws: StructuredEditError.self) {
            try b.proposedContents(originals: ["A.swift": "one"], protected: [], appendOnly: [], maxEdits: 3, maxLines: 6)
        }
    }
    @Test func protectedAndAppendOnlyRejectReplacement() throws {
        for protected in [Set(["T.swift"]), Set<String>()] {
            let b = try batch([replace("T.swift", "assert", "skip")])
            #expect(throws: StructuredEditError.self) {
                try b.proposedContents(originals: ["T.swift": "assert"], protected: protected, appendOnly: ["T.swift"], maxEdits: 2, maxLines: 20)
            }
        }
    }
    @Test func appendPreservesExistingTestsAndBudget() throws {
        let b = try batch([["operation": "append_block", "file": "T.swift", "expected_old_text": "", "new_text": "new test"]])
        #expect(try b.proposedContents(originals: ["T.swift": "old test\n"], protected: [], appendOnly: ["T.swift"], maxEdits: 1, maxLines: 1)["T.swift"] == "old test\nnew test\n")
        #expect(throws: StructuredEditError.self) {
            try b.proposedContents(originals: ["T.swift": "old test\n"], protected: [], appendOnly: ["T.swift"], maxEdits: 1, maxLines: 0)
        }
    }
    @Test func ambiguousAnchorAndNoopRejected() throws {
        for source in ["one one", "absent"] {
            let b = try batch([replace("A.swift", "one", "two")])
            #expect(throws: StructuredEditError.self) {
                try b.proposedContents(originals: ["A.swift": source], protected: [], appendOnly: [], maxEdits: 1, maxLines: 2)
            }
        }
    }
    @Test func backslashPathResolvesOnlyToAnOfferedFile() throws {
        let originals = ["Sources/W/Wallet.swift": "one", "Sources/W/Other.swift": "x"]
        let known = Set(originals.keys)
        let resolved = try batch([replace("Sources\\W\\Wallet.swift", "one", "two")]).resolvingSeparators(knownFiles: known)
        #expect(try resolved.proposedContents(originals: originals, protected: [], appendOnly: [], maxEdits: 1, maxLines: 4)
            == ["Sources/W/Wallet.swift": "two"])
        // Unknown or escaping paths stay as written and are still rejected.
        for path in ["Sources\\W\\Missing.swift", "Sources\\..\\..\\etc\\passwd", "\\Sources\\W\\Wallet.swift"] {
            let kept = try batch([replace(path, "one", "two")]).resolvingSeparators(knownFiles: known)
            #expect(kept.edits.first?.file == path)
            #expect(throws: StructuredEditError.self) {
                try kept.proposedContents(originals: originals, protected: [], appendOnly: [], maxEdits: 1, maxLines: 4)
            }
        }
    }
    @Test func replaceExactMayDeleteButAppendMayNotBeEmpty() throws {
        let delete = try batch([replace("A.swift", "keep\ndrop\n", "keep\n")]).proposedContents(
            originals: ["A.swift": "keep\ndrop\nend"], protected: [], appendOnly: [], maxEdits: 1, maxLines: 6)  // 3 old + 2 new lines
        #expect(delete == ["A.swift": "keep\nend"])
        #expect(try batch([replace("A.swift", "drop\n", "")]).proposedContents(
            originals: ["A.swift": "keep\ndrop\nend"], protected: [], appendOnly: [], maxEdits: 1, maxLines: 4) == ["A.swift": "keep\nend"])
        let emptyAppend = try batch([["operation": "append_block", "file": "T.swift", "expected_old_text": "", "new_text": ""]])
        #expect(throws: StructuredEditError.self) {
            try emptyAppend.proposedContents(originals: ["T.swift": "x\n"], protected: [], appendOnly: ["T.swift"], maxEdits: 1, maxLines: 4)
        }
    }
    @Test func anchorReportCountsMatchesAfterEarlierEdits() throws {
        let source = "let a = 1\nlet b = 2\nlet a = 1\n"
        let b = try batch([replace("A.swift", "let b = 2", "let b = 3"), replace("A.swift", "let a = 1", "let a = 9"),
                           replace("A.swift", "let c = 0", "let c = 1"), replace("A.swift", "let b = 3", "let b = 4")])
        let report = b.anchorReport(originals: ["A.swift": source])
        #expect(report.count == 2)
        #expect(report[0].hasPrefix("edit 2 (A.swift)") && report[0].contains("occurs 2 times (lines 1, 3)"))
        #expect(report[1].hasPrefix("edit 3 (A.swift)") && report[1].contains("occurs 0 times"))
        #expect(try batch([replace("A.swift", "let b = 2", "x")]).anchorReport(originals: ["A.swift": source]).isEmpty)
    }
    @Test func anchorsMatchAcrossUnicodeNormalisationForms() throws {
        // Files written on macOS may hold NFD Japanese while the model answers in NFC; matching must not depend on it.
        let nfc = "let label = \"保留中・ガイド\""
        let file = "struct A {\n    " + nfc.decomposedStringWithCanonicalMapping + "\n}\n"
        #expect(Array(file.utf8) != Array(("struct A {\n    " + nfc + "\n}\n").utf8))
        let result = try batch([replace("A.swift", nfc, "let label = \"完了\"")]).proposedContents(
            originals: ["A.swift": file], protected: [], appendOnly: [], maxEdits: 1, maxLines: 4)
        #expect(result["A.swift"] == "struct A {\n    let label = \"完了\"\n}\n")
        #expect(try batch([replace("A.swift", nfc, "x")]).anchorReport(originals: ["A.swift": file]).isEmpty)
    }
    @Test func zeroMatchAnchorReportsTheFirstDifferingLine() throws {
        let source = "struct Pay {\n    /// Hourly rate in yen.\n    let rate: Int\n    func total(_ h: Int) -> Int { rate * h }\n}\n"
        func report(_ anchor: String) throws -> String {
            try batch([replace("P.swift", anchor, "x")]).anchorReport(originals: ["P.swift": source]).first ?? ""
        }
        let paraphrased = try report("    /// Hourly rate in yen.\n    let rate: Int\n    func total(_ hours: Int) -> Int { rate * hours }")
        #expect(paraphrased.contains("its first 2 of 3 lines match at line 2; line 3 differs"))
        #expect(paraphrased.contains("file has `    func total(_ h: Int) -> Int { rate * h }`"))
        #expect(paraphrased.contains("you wrote `    func total(_ hours: Int) -> Int { rate * hours }`"))
        #expect(paraphrased.contains("Current file lines (numbers are not part of the file):\n2:     /// Hourly rate in yen.\n3:     let rate: Int\n4:     func total(_ h: Int) -> Int { rate * h }\n5: }"))
        #expect(try report("\tlet rate: Int").contains("matches line 3 only when indentation is ignored"))
        #expect(try report("  \"/\"/ Hourly rate in yen.\n    let rate: Int").contains("does not occur in the file"))
    }
    @Test func anchorRepairDoesNotConsumeTheRecoveryCap() {
        var budget = RequirementCoverage.Budget()
        let steps = [budget.consume(.targetReplan), budget.consume(.anchorRepair),
                     budget.consume(.compilerRepair),       // still available after an anchor repair
                     budget.consume(.requirementReplan),    // cap of 2 non-anchor kinds reached
                     budget.consume(.anchorRepair)]         // single use
        #expect(steps == [true, true, true, false, false])
        var other = RequirementCoverage.Budget()
        let order = [other.consume(.targetReplan), other.consume(.compilerRepair), other.consume(.anchorRepair)]
        #expect(order == [true, true, true])
    }
    @Test func fencedOrPrefacedJSONIsUnwrappedButContentStillValidated() throws {
        let body = #"{"edits":[{"operation":"replace_exact","file":"A.swift","expected_old_text":"one","new_text":"two {x}"}]}"#
        for wrapped in ["```json\n" + body + "\n```", "I will change one line.\n" + body + "\nDone.", body] {
            let text = StructuredResponseText.jsonObject(in: wrapped)
            let batch = try JSONDecoder().decode(StructuredEditBatch.self, from: Data(text.utf8))
            #expect(try batch.proposedContents(originals: ["A.swift": "one"], protected: [], appendOnly: [], maxEdits: 1, maxLines: 4)
                == ["A.swift": "two {x}"])
        }
        #expect(StructuredResponseText.jsonObject(in: "no json here") == "no json here")       // still rejected by the decoder
        #expect(StructuredResponseText.jsonObject(in: "```json\n{\"edits\": [") == "```json\n{\"edits\": [")  // truncated stays invalid
    }
}
