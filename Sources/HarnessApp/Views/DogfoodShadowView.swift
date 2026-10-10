import AppKit
import Foundation
import HarnessExecution
import SwiftUI

/// Developer-only D0 entry point. It reads paths and saves a plan, never edits source.
struct DogfoodShadowView: View {
    let sourcePath: String?
    @State private var rootPath = ""
    @State private var selectedFolder: URL?
    @State private var objective = ""
    @State private var result: DogfoodShadowResult?
    @State private var resultPath: String?
    @State private var errorMessage: String?
    @State private var isPlanning = false
    @State private var progressPath = ""
    @State private var explorationMilliseconds: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("開発モード · Shadow")
                    .font(.harness(.title2, weight: .semibold))
                Text("Local Factoryが作業案を作ります。この段階ではファイルの編集やAIの実行はしません。")
                    .foregroundStyle(.secondary)
                Text(rootPath.isEmpty ? "Candidateのソースフォルダを選んでください" : rootPath)
                    .font(.harness(.caption))
                    .textSelection(.enabled)
                Button("フォルダを選ぶ") { chooseFolder() }
                TextField("何を直したいですか？", text: $objective, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                Button("Shadowで作業案を作る") { createPlan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPlanning || selectedFolder == nil
                              || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isPlanning {
                    ProgressView("候補ファイルを調べています")
                    Text(progressPath).font(.harness(.caption)).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if let result {
                    Divider()
                    Label("作業案を保存しました", systemImage: "doc.text")
                        .font(.harness(.headline))
                    if let explorationMilliseconds {
                        Text("候補の調査: \(explorationMilliseconds) ms")
                            .font(.harness(.caption)).foregroundStyle(.secondary)
                    }
                    Text("担当候補: \(result.route.route.rawValue) · \(result.route.reason)")
                    Text("候補ファイル")
                        .font(.harness(.headline))
                    ForEach(result.selectedFiles, id: \.self) { Text($0).font(.harness(.caption)).textSelection(.enabled) }
                    Text("確認候補")
                        .font(.harness(.headline))
                    ForEach(result.selectedTests, id: \.self) { Text($0).font(.harness(.caption)).textSelection(.enabled) }
                    ForEach(result.risks, id: \.self) { Text($0).foregroundStyle(.orange) }
                    if let resultPath {
                        Text("記録: \(resultPath)").font(.harness(.caption)).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(28)
        }
        .onAppear { if rootPath.isEmpty { rootPath = sourcePath ?? "" } }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "このフォルダを使う"
        if let sourcePath { panel.directoryURL = URL(fileURLWithPath: sourcePath) }
        if panel.runModal() == .OK, let url = panel.url {
            selectedFolder = url
            rootPath = url.path
        }
    }

    private func createPlan() {
        isPlanning = true
        progressPath = ""
        guard let selectedFolder else { return }
        let source = selectedFolder.path
        let request = objective
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> PlanOutcome in
                do {
                    let accessed = selectedFolder.startAccessingSecurityScopedResource()
                    defer { if accessed { selectedFolder.stopAccessingSecurityScopedResource() } }
                    return .saved(try await DogfoodShadowWorkspace().createPlan(
                        rootPath: source, objective: request,
                        onProgress: { path in Task { @MainActor in progressPath = path } }))
                } catch {
                    return .failed(error.localizedDescription)
                }
            }.value
            switch outcome {
            case let .saved(saved):
                result = saved.result
                resultPath = saved.path
                explorationMilliseconds = saved.explorationMilliseconds
                errorMessage = nil
            case let .failed(message):
                errorMessage = "作業案を作れませんでした: \(message)"
            }
            isPlanning = false
        }
    }
}

private enum PlanOutcome: Sendable {
    case saved(DogfoodShadowWorkspace.SavedPlan)
    case failed(String)
}
