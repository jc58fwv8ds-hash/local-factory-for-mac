import AppKit
import Foundation
import HarnessCore
import SwiftUI
import Testing
@testable import HarnessApp

// 一時的: GUI の見た目を画像に描き出して確認する(コミットしない)。
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_RENDER_OUT"] != nil))
func renderChatCenteredSnapshot() async throws {
    let env = ProcessInfo.processInfo.environment
    let store = WorkspaceStore(repository: WorkspaceRepository(fileURL: URL(fileURLWithPath: env["HARNESS_RENDER_WORKSPACE"]!)))
    let message = ConversationMessage(role: .user, content: "同じ公演8枚以上の注文は団体割引10%にして。介助者の無料券は枚数に数えないで")
    store.library.updateSelectedProject { $0.conversation.append(message) }
    let change = ChatChange(id: message.id, instruction: message.content)
    let editor = ProjectFileEditor()
    let original = "public enum Slug {\n    public static func make(_ t: String) -> String { t }\n}\n"
    change.proposals = [try await editor.makeProposal(document: EditableSourceDocument(relativePath: "Sources/TextKit/Slug.swift", content: original),
                                                proposedContent: original.replacingOccurrences(of: "{ t }", with: "{ t.trimmingCharacters(in: .punctuationCharacters) }"))]
    let record = URL(fileURLWithPath: env["HARNESS_RENDER_RECORD"]!)
    change.cautions = WorkspaceStore.chatChangeCautions(record: record, instruction: message.content)
    change.examples = WorkspaceStore.chatExamples(record: record)
    change.status = .ready
    store.chatChanges[message.id] = change
    store.selectedSection = .home
    let view = RootView(store: store).frame(width: 1280, height: 1000)
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 1000)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(800))
    hosting.layoutSubtreeIfNeeded()
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: env["HARNESS_RENDER_OUT"]!))
}
