import Foundation
import Testing
@testable import HarnessExecution

struct DogfoodShadowPlannerTests {
    @Test func nearbyTaskFindsRelevantFilesWithoutExecutingWorker() throws {
        let input = DogfoodShadowInput(taskID: "pm-transfer-status",
            objective: "iPhoneからMacへの録音転送の状態を画面で分かりやすく表示して。通信の中身は変えないで。",
            repositoryPaths: [
                "work/PersonalMemory/PersonalMemory/NearbyChunkSender.swift",
                "work/PersonalMemory/PersonalMemory/PersonalMemoryApp.swift",
                "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/NearbyChunkReceiver.swift",
                "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/MemoryCalendarApp.swift",
                "work/PersonalMemory/CalendarAssistant/Tests/CalendarDomainTests/SessionChunkWorkspaceTests.swift",
                "work/PersonalMemory/PersonalMemoryUITests/PersonalMemoryUITests.swift",
                "Benchmarks/Dogfood/Results/prior.md",
                "Sources/HarnessKernel/KernelState.swift"
            ], localModelCompatible: false,
            externalReadiness: ExternalDispatchReadiness(ready: false, reasons: ["billing-unverified"], inferenceCalls: 0),
            solAvailable: true, astraAvailable: true)
        let result = try DogfoodShadowPlanner.plan(input, evidence: [
            .init(path: "work/PersonalMemory/PersonalMemory/PersonalMemoryApp.swift",
                  source: "import SwiftUI\nText(\"録音をMacへ送る\")\nNearbyChunkSender()"),
            .init(path: "work/PersonalMemory/PersonalMemory/NearbyChunkSender.swift",
                  source: "var status = \"録音を転送中\""),
            .init(path: "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/NearbyChunkReceiver.swift",
                  source: "final class NearbyChunkReceiver { var status = \"Macで録音を受信\" }")
        ])
        #expect(result.phase == "D0-shadow")
        #expect(result.selectedFiles.contains("work/PersonalMemory/PersonalMemory/NearbyChunkSender.swift"))
        #expect(result.selectedFiles.first == "work/PersonalMemory/PersonalMemory/PersonalMemoryApp.swift")
        #expect(!result.selectedFiles.contains("Sources/HarnessKernel/KernelState.swift"))
        #expect(!result.selectedFiles.contains("Benchmarks/Dogfood/Results/prior.md"))
        #expect(result.selectedTests.first == "work/PersonalMemory/PersonalMemoryUITests/PersonalMemoryUITests.swift")
        #expect(result.workClassification == .focusedEdit)
        #expect(result.route.route == .blocked)
        #expect(result.externalModelCalls == 0 && result.repositoryWrites == 0)
        #expect(result.risks.contains { $0.contains("実機") })
    }

    @Test func unsafeCatalogPathIsRejected() {
        let input = DogfoodShadowInput(taskID: "unsafe", objective: "表示を直して",
            repositoryPaths: ["../outside.swift"], localModelCompatible: false,
            externalReadiness: ExternalDispatchReadiness(ready: false, reasons: [], inferenceCalls: 0),
            solAvailable: false, astraAvailable: false)
        #expect(throws: DogfoodShadowPlanner.Failure.self) {
            try DogfoodShadowPlanner.plan(input)
        }
    }

    @Test func macRecordingStatusPrefersPersonalMemoryReceiverToGenericViews() throws {
        let input = DogfoodShadowInput(taskID: "pm-mac-recording-status",
            objective: "Macに届いた録音の状態を分かりやすく表示したい。",
            repositoryPaths: [
                "HarnessRemote/HarnessRemote/ContentView.swift",
                "Sources/HarnessApp/ExternalReviewHandoff.swift",
                "work/PersonalMemory/PersonalMemory/PersonalMemoryApp.swift",
                "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/MemoryCalendarApp.swift",
                "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/NearbyChunkReceiver.swift",
                "work/PersonalMemory/CalendarAssistant/Tests/CalendarDomainTests/SessionChunkWorkspaceTests.swift"
            ], localModelCompatible: false,
            externalReadiness: ExternalDispatchReadiness(ready: false,
                reasons: ["not ready"], inferenceCalls: 0),
            solAvailable: false, astraAvailable: false)
        let result = try DogfoodShadowPlanner.plan(input, evidence: [
            .init(path: "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/MemoryCalendarApp.swift",
                  source: "import AppKit\nText(\"受信済み録音\")\nNearbyChunkReceiver()"),
            .init(path: "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/NearbyChunkReceiver.swift",
                  source: "var status = \"録音をMacで受信\""),
            .init(path: "work/PersonalMemory/PersonalMemory/PersonalMemoryApp.swift",
                  source: "Text(\"録音をMacへ送る\")")
        ])
        #expect(result.selectedFiles.first ==
            "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/MemoryCalendarApp.swift")
        #expect(result.selectedFiles.contains(
            "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/NearbyChunkReceiver.swift"))
        #expect(!result.selectedFiles.contains("HarnessRemote/HarnessRemote/ContentView.swift"))
    }

    @Test func macRecordingLabelIsNotMisclassifiedAsIPhoneTransferStatus() throws {
        let input = DogfoodShadowInput(taskID: "pm-received-label",
            objective: "Mac側の受信済み録音画面で長いハッシュのファイル名を主表示しないで。録音日時を読みやすく表示し、転送・保存の中身は変えない。",
            repositoryPaths: [
                "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/MemoryCalendarApp.swift",
                "work/PersonalMemory/PersonalMemory/PersonalMemoryApp.swift"
            ], localModelCompatible: false,
            externalReadiness: ExternalDispatchReadiness(ready: false,
                reasons: ["not ready"], inferenceCalls: 0),
            solAvailable: false, astraAvailable: false)
        let result = try DogfoodShadowPlanner.plan(input, evidence: [
            .init(path: "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/MemoryCalendarApp.swift",
                  source: "import AppKit\nLabel(\"受信済み録音日時\", systemImage: \"waveform\")"),
            .init(path: "work/PersonalMemory/PersonalMemory/PersonalMemoryApp.swift",
                  source: "Text(\"録音をMacへ送る\")")
        ])
        #expect(result.selectedFiles == [
            "work/PersonalMemory/CalendarAssistant/Sources/MemoryCalendarApp/MemoryCalendarApp.swift"])
    }
}
