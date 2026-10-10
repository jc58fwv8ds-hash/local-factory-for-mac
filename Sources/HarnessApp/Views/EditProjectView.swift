import HarnessCore
import SwiftUI

struct EditProjectView: View {
    let record: ProjectRecord
    let onSave: (ProjectDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProjectDraft

    init(record: ProjectRecord, onSave: @escaping (ProjectDraft) -> Void) {
        self.record = record
        self.onSave = onSave
        _draft = State(initialValue: ProjectDraft(project: record.project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("プロジェクト情報を編集")
                    .font(.harness(.title2, weight: .bold))
                Text("名前、説明、対象端末、現在の制作ステージを変更できます。")
                    .font(.harness(.subheadline))
                    .foregroundStyle(.secondary)
            }

            ProjectFormFields(draft: $draft, showsStage: true)

            HStack {
                if let sourceLocation = record.sourceLocation {
                    Label(sourceLocation, systemImage: "folder")
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
        }
        .padding(26)
        .frame(width: 640, height: 520)
    }
}
