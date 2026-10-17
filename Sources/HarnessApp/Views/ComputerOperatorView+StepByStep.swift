import HarnessCore
import SwiftUI

/// The 「アプリを一手ずつ操作する」 part of the Computer Operator screen (Computer Use stage 1, 2026-10-18).
extension ComputerOperatorView {
    /// Computer Use stage 1: the agent looks at the frontmost app and acts one step at a time.
    var stepByStepSection: some View {
        let use = store.computerUse
        return VStack(alignment: .leading, spacing: 9) {
            Text("アプリを一手ずつ操作する(試験)")
                .font(.harness(.headline))
            Text("前面のアプリの画面を読み、AI が一手ずつ操作します。送信・購入・削除などの前には毎回確認し、パスワードは入力しません。")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            HStack {
                TextField("例: メモを開いて「買い物リスト」という新しいメモを作って", text: Bindable(use).goal)
                    .textFieldStyle(.roundedBorder)
                    .disabled(use.isRunning)
                if use.isRunning {
                    Button("止める") { use.stop() }
                } else {
                    Button("始める") {
                        if let model = store.project.selectedModel { use.start(model: model, provider: store.inferenceProvider) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(use.goal.trimmingCharacters(in: .whitespaces).isEmpty || store.project.selectedModel == nil)
                }
            }
            ForEach(Array(use.steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step.action) → \(step.result)").font(.harness(.caption))
            }
            if let approval = use.pendingApproval {
                VStack(alignment: .leading, spacing: 6) {
                    Label("この操作をしてよいですか", systemImage: "exclamationmark.shield").font(.harness(.subheadline, weight: .semibold))
                    Text(approval.action).font(.harness(.body))
                    Text(approval.reason).font(.harness(.caption)).foregroundStyle(.secondary)
                    HStack {
                        Button("する") { use.answer(true) }.buttonStyle(.borderedProminent)
                        Button("しない(止める)") { use.answer(false) }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            if let outcome = use.outcome { Text(outcome).font(.harness(.caption, weight: .semibold)) }
        }
    }
}
