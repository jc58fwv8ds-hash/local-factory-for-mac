import Foundation
import HarnessCore
import Testing

struct SDKMemberLookupTests {
    @Test func readsTheMissingMember() {
        let found = SDKMemberLookup.missingMember(in: "value of type 'AVAudioSessionPortDescription' has no member 'portDescription'")
        #expect(found?.type == "AVAudioSessionPortDescription" && found?.member == "portDescription")
        #expect(SDKMemberLookup.missingMember(in: "cannot find 'x' in scope") == nil)
    }

    @Test func listsTheRealNamesFromTheSDK() {
        let names = SDKMemberLookup.shared.members(of: "AVAudioSessionPortDescription")
        #expect(names.contains("portName") && names.contains("portType"))
        let target = BuildRepairTarget(relativePath: "A.swift", diagnostics: [
            .init(validationKind: .build, relativePath: "A.swift", line: 3, column: 1,
                  message: "value of type 'AVAudioSessionPortDescription' has no member 'port'")])
        #expect(target.instruction.contains("portName"))
    }
}

struct BuildErrorAdviceTests {
    @Test func advisesOnMainActorMutationFromAClosure() {
        let lines = BuildErrorAdvice.lines(for: [
            "main actor-isolated property 'isListening' can not be mutated from a nonisolated context",
            "main actor-isolated property 'partialText' can not be mutated from a nonisolated context"])
        #expect(lines.count == 1 && lines[0].contains("Task { @MainActor"))
        #expect(BuildErrorAdvice.lines(for: ["expected expression"]).isEmpty)
    }
}

struct RepairPlaceTests {
    @Test func namesTheDeinitOrFunctionAroundTheError() {
        let source = """
        final class A {
            var x = 0
            func run() {
                x = 1
            }
            deinit {
                x = 2
            }
        }
        """
        let target = BuildRepairTarget(relativePath: "A.swift", diagnostics: [
            .init(validationKind: .xcodeBuild, relativePath: "A.swift", line: 7, column: 1, message: "e"),
            .init(validationKind: .xcodeBuild, relativePath: "A.swift", line: 4, column: 1, message: "e")])
        let text = target.instruction(source: source)
        #expect(text.contains("行7 は deinit の中"))
        #expect(text.contains("行4 は func run(…) の中"))
    }
}

struct DeinitAdviceTests {
    @Test func tellsToEmptyANonisolatedDeinit() {
        let lines = BuildErrorAdvice.lines(for: [
            "cannot access property 'recognitionRequest' with a non-Sendable type 'SFSpeechAudioBufferRecognitionRequest?' from nonisolated deinit"])
        #expect(lines.first?.contains("deinit の中身はすべて消して") == true)
    }
}

struct DegenerateOutputTests {
    @Test func stopsOnATailOfBlanks() {
        #expect(DegenerateOutput.isRunaway("{\"content\":\"import A\\n" + String(repeating: " ", count: 2_000)))
        #expect(DegenerateOutput.isRunaway("x" + String(repeating: "\\n    ", count: 400)))
        #expect(!DegenerateOutput.isRunaway(String(repeating: "let a = 1\n", count: 400)))
        #expect(!DegenerateOutput.isRunaway("short   "))
    }
}

struct HeaderPrototypeLookupTests {
    @Test func findsTheDeclarationOfACalledCFunction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let headers = root.appendingPathComponent("Frameworks/lib.xcframework/ios-arm64/lib.framework/Headers")
        try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        // tokens
            LLAMA_API int32_t llama_tokenize(
                const struct llama_vocab * vocab,
                          const char * text,
                             bool   parse_special);
        """.write(to: headers.appendingPathComponent("lib.h"), atomically: true, encoding: .utf8)
        let found = HeaderPrototypeLookup.prototypes(forLines: ["let n = llama_tokenize(vocab, text, 1)"], projectRoot: root)
        #expect(found == ["LLAMA_API int32_t llama_tokenize( const struct llama_vocab * vocab, const char * text, bool parse_special);"])
        let advice = BuildErrorAdvice.lines(for: ["cannot assign value of type 'UnsafeMutablePointer<llama_sampler>?' to type 'OpaquePointer?'"])
        #expect(advice.first?.contains("ポインタの型") == true)
    }
}

struct ArrayPointerAdviceTests {
    @Test func tellsHowToPassAnArrayToACPointer() {
        let lines = BuildErrorAdvice.lines(for: ["cannot convert value of type '[Int32]' to expected argument type 'UnsafeMutablePointer<llama_token>' (aka 'UnsafeMutablePointer<Int32>')"])
        #expect(lines.contains { $0.contains("&tokens") })
    }
}

struct TestFailureAnalyzerTests {
    @Test func aFailedTestBecomesARepairOfTheFileItTestsWithTheTrapAdvice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AppTests"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "actor PlamoTranslator {}".write(to: root.appendingPathComponent("App/PlamoTranslator.swift"), atomically: true, encoding: .utf8)
        try "struct T {}".write(to: root.appendingPathComponent("AppTests/PlamoTranslatorTests.swift"), atomically: true, encoding: .utf8)
        let output = """
        Testing on iPhoneSimulator
        ggml_metal_init: found device
        llama_context: n_ctx = 2048
        ✘ Test translatesAnEnglishSentenceIntoJapanese() recorded an issue at PlamoTranslatorTests.swift:12:9: Expectation failed: !result.isEmpty
        ↳ !result.isEmpty → true
        ↳     result → ""
        ** TEST FAILED **
        """
        let found = TestFailureAnalyzer.diagnostics(output: output, rootURL: root, kind: .xcodeTest)
        #expect(found.count == 1)
        #expect(found.first?.relativePath == "App/PlamoTranslator.swift")
        let target = BuildRepairTarget(relativePath: "App/PlamoTranslator.swift", diagnostics: found)
        #expect(target.instruction.contains("n_gpu_layers = 0"))
        #expect(target.instruction.contains("BOS"))
    }
}

struct SigningTeamDetectorTests {
    @Test func aTeamIsTenCapitalLettersAndDigits() {
        #expect(SigningTeamDetector.isTeamIdentifier("AB12CD34EF"))
        #expect(!SigningTeamDetector.isTeamIdentifier("ab12cd34ef"))
        #expect(!SigningTeamDetector.isTeamIdentifier("Apple Development"))
    }

    @Test func theAutomaticTeamSatisfiesTheTeamRequirementOnly() {
        // Readiness: with a team found on this Mac, 「select a development team」 is no longer asked of the user.
        #expect(PhysicalDeviceSetupRequirement.selectDevelopmentTeam == .selectDevelopmentTeam)
    }
}

struct ProjectMemberLookupTests {
    @Test func listsTheMembersOfATypeMadeInTheProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        @MainActor
        final class SpeechListener: ObservableObject {
            @Published var partialText: String = ""
            var onFinalSentence: ((String) -> Void)?
            private let engine = 1
            init(locale: Locale = Locale(identifier: "en-US")) {}
            func start() async throws {
                let request = 1
            }
            func stop() {}
        }
        """.write(to: root.appendingPathComponent("App/SpeechListener.swift"), atomically: true, encoding: .utf8)
        let hint = ProjectMemberLookup.hint(for: "value of type 'SpeechListener' has no member 'transcript'", projectRoot: root)
        #expect(hint?.contains("partialText") == true && hint?.contains("onFinalSentence") == true)
        #expect(hint?.contains("start()") == true && hint?.contains("engine") == false && hint?.contains("request") == false)
    }
}

struct ThrowsAndAsyncAdviceTests {
    @Test func tellsHowToHandleThrowingAndAsyncCalls() {
        #expect(BuildErrorAdvice.lines(for: ["call can throw, but it is not marked with 'try' and the error is not handled"]).first?.contains("try") == true)
        #expect(BuildErrorAdvice.lines(for: ["'async' call in a function that does not support concurrency"]).first?.contains("Task {") == true)
        #expect(BuildErrorAdvice.lines(for: ["'async' call in a function that does not support concurrency"]).first?.contains("MainActor.run") == true)
        #expect(BuildErrorAdvice.lines(for: ["sending 'buffer' risks causing data races"]).first?.contains("その場で使い切って") == true)
        #expect(BuildErrorAdvice.lines(for: ["value of type '[String]' has no member 'unicodeScalars'"]).first?.contains("joined") == true)
    }
}

struct ThrowingInitAdviceTests {
    @Test func aThrowingCallInAnInitializerGetsTheChangeOfShape() {
        let source = """
        final class A {
            let b: B
            init() {
                self.b = B(url: u)
            }
        }
        """
        let target = BuildRepairTarget(relativePath: "A.swift", diagnostics: [
            .init(validationKind: .xcodeBuild, relativePath: "A.swift", line: 4, column: 1,
                  message: "call can throw, but it is not marked with 'try' and the error is not handled")])
        #expect(target.instruction(source: source).contains("Optional"))
    }
}

struct FinalClassAdviceTests {
    @Test func tellsNotToSubclassAFinalClassInATest() {
        #expect(BuildErrorAdvice.lines(for: ["inheritance from a final class 'AudioRoute'"]).first?.contains("本物の型") == true)
    }
}

struct RedeclarationRetargetTests {
    @Test func theNewestDeclaringFileIsTheOneToChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("App/Controller.swift"), new = root.appendingPathComponent("App/Screen.swift")
        try "final class Controller {}".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: old.path)
        try "struct Screen {}\nfinal class Controller {}".write(to: new, atomically: true, encoding: .utf8)
        let found = RedeclarationRetarget.retarget([.init(validationKind: .xcodeBuild, relativePath: "App/Controller.swift",
            line: 1, column: 13, message: "invalid redeclaration of 'Controller'")], rootURL: root)
        #expect(found.first?.relativePath == "App/Screen.swift")
        #expect(found.first?.message.contains("Controller.swift にある Controller をそのまま使って") == true)
    }
}

struct MissingMemberRetargetTests {
    @Test func aMemberNoneResemblesIsAddedToTheTypesFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "final class Controller: ObservableObject {\n    @Published var isRunning = false\n}"
            .write(to: root.appendingPathComponent("App/Controller.swift"), atomically: true, encoding: .utf8)
        let diagnostic = BuildFailureDiagnostic(validationKind: .xcodeBuild, relativePath: "App/Screen.swift", line: 13, column: 3,
            message: "value of type 'Controller' has no dynamic member 'speakerEnabled' using key path from root type 'Controller'")
        let found = MissingMemberRetarget.retarget([diagnostic, diagnostic], rootURL: root)
        #expect(found.count == 1 && found[0].relativePath == "App/Controller.swift")
        #expect(found[0].message.contains("Controller に speakerEnabled を足して"))
        // A near name is a misspelling to fix where it is used.
        let near = BuildFailureDiagnostic(validationKind: .xcodeBuild, relativePath: "App/Screen.swift", line: 1, column: 1,
            message: "value of type 'Controller' has no member 'isRunnin'")
        #expect(MissingMemberRetarget.retarget([near], rootURL: root).first?.relativePath == "App/Screen.swift")
    }
}

struct ProvisioningProfileRenewalTests {
    @Test func onlyTheAppsProfilesNearTheirEndAreRetired() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, _ identifier: String, _ expires: Date) throws {
            let plist: [String: Any] = ["ExpirationDate": expires, "Entitlements": ["application-identifier": "TEAMID1234." + identifier]]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: directory.appendingPathComponent(name + ".mobileprovision"))
        }
        let now = Date()
        try write("a", "local.harness.personalmemory", now.addingTimeInterval(86_400))                 // 1 day left
        try write("b", "local.harness.personalmemory.watchkitapp", now.addingTimeInterval(3_600))     // its Watch app
        try write("c", "local.harness.harnessremote", now.addingTimeInterval(86_400))                  // another app
        try write("d", "local.harness.personalmemory", now.addingTimeInterval(6 * 86_400))             // fresh
        var trashed: [String] = []
        let moved = ProvisioningProfileRenewal.retireExpiring(bundleIdentifier: "local.harness.personalmemory", now: now,
                                                             directories: [directory], trash: { trashed.append($0.lastPathComponent) })
        #expect(moved == 2 && Set(trashed) == ["a.mobileprovision", "b.mobileprovision"])
    }
}
