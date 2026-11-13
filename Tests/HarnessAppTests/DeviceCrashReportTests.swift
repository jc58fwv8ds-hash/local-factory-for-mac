import Foundation
import Testing
@testable import HarnessCore

struct DeviceCrashReportTests {
    static let ips = #"{"app_name":"FourteenTranslate","bug_type":"309"}"# + "\n" + #"""
    {"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"termination":{"indicator":"Trace/BPT trap: 5"},
     "usedImages":[{"name":"libdispatch.dylib"},{"name":"libswift_Concurrency.dylib"},{"name":"FourteenTranslate.debug.dylib"},{"name":"TCC"}],
     "threads":[{"frames":[]},{"triggered":true,"frames":[
       {"imageIndex":0,"symbol":"_dispatch_assert_queue_fail"},
       {"imageIndex":1,"symbol":"swift_task_isCurrentExecutorWithFlagsImpl"},
       {"imageIndex":2,"symbol":"closure #1 in closure #1 in SpeechListener.start()"},
       {"imageIndex":3,"symbol":"__TCCAccessRequest_block_invoke_8"}]}]}
    """#

    @Test func readsTheAppFrameAndTheIsolationCause() throws {
        let report = try #require(DeviceCrashReport.parse(Self.ips, appName: "FourteenTranslate"))
        #expect(report.exception == "EXC_BREAKPOINT SIGTRAP")
        #expect(report.appFrames == ["closure #1 in closure #1 in SpeechListener.start()"])
        #expect(report.typeName == "SpeechListener")
        #expect(report.advice.contains("Task { @MainActor in"))
        #expect(report.plainSummary == "アプリはマイクや音声認識を使ってよいかの返事を受け取るところで止まっていました。")
    }

    @Test func findsTheDeclaringFileAndNewestNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crash-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "final class SpeechListener {}".write(to: root.appendingPathComponent("App/SpeechListener.swift"), atomically: true, encoding: .utf8)
        #expect(DeviceCrashFile.declaring("SpeechListener", under: root) == "App/SpeechListener.swift")
        let listing = """
        FourteenTranslate-2026-11-11-180930.ips      Readable  7 KB
        FourteenTranslate-2026-11-11-182458.000.ips  Readable  7 KB
        FourteenTranslate-2026-11-11-182458.ips      Readable  7 KB
        Other-2026-11-11-182500.ips                  Readable  7 KB
        """
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let since = try #require(formatter.date(from: "2026-11-11-181000"))
        #expect(DeviceCrashLogs.names(in: listing, appName: "FourteenTranslate", since: since) == ["FourteenTranslate-2026-11-11-182458.ips"])
    }
}
