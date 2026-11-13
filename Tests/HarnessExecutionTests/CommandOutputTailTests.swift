import Foundation
@testable import HarnessCore
import Testing

struct CommandOutputTailTests {
    @Test(arguments: [0, 3, 4, 5, 8_193])
    func byteLimitAndTruncationAreExact(length: Int) throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 65, count: length).write(to: file)
        let tail = try CommandOutputTail(file: file, maximumBytes: 4)
        #expect(tail.text == String(repeating: "A", count: min(4, length)))
        #expect(tail.wasTruncated == (length > 4))
    }

    @Test func sparseLargeLogOnlyReturnsItsTail() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        // A sparse fixture exercises large offsets without generating megabytes of logs.
        try writer.seek(toOffset: 128 * 1_024 * 1_024)
        try writer.write(contentsOf: Data("done".utf8))
        let tail = try CommandOutputTail(file: file, maximumBytes: 4)
        #expect(tail.text == "done")
        #expect(tail.wasTruncated)
    }

    @Test func errorsOfTheDroppedHeadAreKept() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let log = "/p/A.swift:3:5: error: cannot find 'x' in scope\n" + String(repeating: "noise\n", count: 2_000) + "Testing failed: (3 failures)"
        try Data(log.utf8).write(to: file)
        let tail = try CommandOutputTail(file: file, maximumBytes: 64)
        #expect(tail.text.hasPrefix("(前の部分のエラー)\n/p/A.swift:3:5: error: cannot find 'x' in scope"))
        #expect(tail.text.hasSuffix("Testing failed: (3 failures)"))
    }

    @Test func failedTestLinesOfTheDroppedHeadAreKept() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let log = "✘ Test convertsThreeBons() recorded an issue at JapaneseSpeakerTests.swift:9:9: Expectation failed: result == \"さんぼん\"\n  ↳ result → \"さんほん\"\n"
            + String(repeating: "llama noise\n", count: 2_000) + "** TEST FAILED **"
        try Data(log.utf8).write(to: file)
        let tail = try CommandOutputTail(file: file, maximumBytes: 64)
        #expect(tail.text.contains("JapaneseSpeakerTests.swift:9:9: Expectation failed"))
        #expect(tail.text.contains("↳ result → \"さんほん\""))
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6])
    func japaneseBoundaryDoesNotIntroduceReplacementCharacters(limit: Int) throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("日本語".utf8).write(to: file)
        let tail = try CommandOutputTail(file: file, maximumBytes: limit)
        #expect(tail.text == (limit < 3 ? "" : limit < 6 ? "語" : "本語"))
        #expect(tail.wasTruncated)
    }

    @Test func unreadableLogThrowsInsteadOfReturningEmptySuccess() {
        #expect(throws: (any Error).self) {
            try CommandOutputTail(file: temporaryFile(), maximumBytes: 4)
        }
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HarnessTail-\(UUID()).log")
    }
}
