import Foundation
@testable import HarnessCore
import Testing

struct SDKSwiftInterfaceLookupTests {
    @Test func aNamedTypeAndThePartsItIsBuiltFromAreShownAsDeclared() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString)")
        let module = root.appendingPathComponent("System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try """
        public protocol SpeechModule : AnyObject, Swift::Sendable {
        }
        @available(iOS 26.0, *)
        final public actor SpeechAnalyzer : Swift::Sendable {
          public convenience init(modules: [any Speech::SpeechModule])
          final public func start<S>(inputSequence: S) async throws
        }
        final public class SpeechTranscriber : Speech::SpeechModule {
          convenience public init(locale: Foundation::Locale, preset: Speech::SpeechTranscriber.Preset)
        }
        public struct Unrelated {
        }
        """.write(to: module.appendingPathComponent("arm64e-apple-ios.swiftinterface"), atomically: true, encoding: .utf8)
        let lookup = SDKSwiftInterfaceLookup(sdkPath: { root.path })
        let text = try #require(lookup.reference(for: "聞き取りを SpeechAnalyzer に替えて"))
        #expect(text.contains("public convenience init(modules: [any SpeechModule])"))
        #expect(text.contains("convenience public init(locale: Locale, preset: SpeechTranscriber.Preset)"))
        #expect(!text.contains("SpeechAnalyzer(recognizer"))
        #expect(lookup.reference(for: "画面を直して") == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aMissingMemberShowsTheRealOnesWithANearNameOnOtherTypes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString)")
        let module = root.appendingPathComponent("System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try """
        final public class AssetInventory {
          public static func assetInstallationRequest(supporting modules: [any Speech::SpeechModule]) async throws -> Speech::AssetInstallationRequest?
        }
        final public class SpeechTranscriber : Speech::SpeechModule {
          public static var supportedLocales: [Foundation::Locale] {
            get async
          }
          public static var isAvailable: Swift::Bool {
            get
          }
        }
        final public class AssetInstallationRequest : ObjectiveC::NSObject {
          final public func downloadAndInstall() async throws
        }
        """.write(to: module.appendingPathComponent("arm64e-apple-ios.swiftinterface"), atomically: true, encoding: .utf8)
        let lookup = SDKSwiftInterfaceLookup(sdkPath: { root.path })
        let text = try #require(lookup.nearMembers(for: "type 'SpeechTranscriber' has no member 'downloadLocale'"))
        #expect(text.contains("AssetInstallationRequest: final public func downloadAndInstall() async throws"))
        #expect(text.contains("SpeechTranscriber: public static var supportedLocales: [Locale]"))
        #expect(text.contains("AssetInventory: public static func assetInstallationRequest(supporting modules: [any SpeechModule])"))
        #expect(!text.contains("isAvailable"))
        #expect(lookup.nearMembers(for: "type 'SpeechTranscriber' has no member 'go'") == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aMissingMemberOfANestedTypeShowsWhatThatTypeHas() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString)")
        let module = root.appendingPathComponent("System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try """
        final public class DictationTranscriber : Speech::SpeechModule {
          public struct Preset : Swift::Sendable {
            public static let phrase: Speech::DictationTranscriber.Speech::Preset
          }
        }
        final public class SpeechTranscriber : Speech::SpeechModule {
          convenience public init(locale: Foundation::Locale, preset: Speech::SpeechTranscriber.Speech::Preset)
          public struct Preset : Swift::Sendable {
            public static let transcription: Speech::SpeechTranscriber.Speech::Preset
            public static let progressiveTranscription: Speech::SpeechTranscriber.Speech::Preset
          }
        }
        """.write(to: module.appendingPathComponent("arm64e-apple-ios.swiftinterface"), atomically: true, encoding: .utf8)
        let lookup = SDKSwiftInterfaceLookup(sdkPath: { root.path })
        let text = try #require(lookup.nearMembers(for: "type 'SpeechTranscriber.Preset' has no member 'general'"))
        #expect(text.contains("public static let progressiveTranscription: SpeechTranscriber.Preset"))
        #expect(!text.contains("phrase"))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func thePlannerIsToldTheAppleTypesTheProjectUsesAndTheirNeighbours() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString)")
        let module = root.appendingPathComponent("System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try """
        final public actor SpeechAnalyzer : Swift::Sendable {
        }
        final public class DictationTranscriber : Speech::SpeechModule {
        }
        """.write(to: module.appendingPathComponent("arm64e-apple-ios.swiftinterface"), atomically: true, encoding: .utf8)
        let project = root.appendingPathComponent("Project/App")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "let analyzer = SpeechAnalyzer(modules: [])\n".write(to: project.appendingPathComponent("Listener.swift"), atomically: true, encoding: .utf8)
        let lookup = SDKSwiftInterfaceLookup(sdkPath: { root.path })
        let text = try #require(lookup.projectReference(rootURL: root.appendingPathComponent("Project")))
        #expect(text.contains("Speech: 使っている型 SpeechAnalyzer"))
        #expect(text.contains("final public class DictationTranscriber : SpeechModule"))
        let messages = try ArtifactPlanPromptBuilder.messages(instruction: "代わりの聞き取りを本物に", existingPaths: ["App/Listener.swift"],
                                                              platformReference: text)
        #expect(messages.last?.content.contains("DictationTranscriber") == true)
        try? FileManager.default.removeItem(at: root)
    }
}
