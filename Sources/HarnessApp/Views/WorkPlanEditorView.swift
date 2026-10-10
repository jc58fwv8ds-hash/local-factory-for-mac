import HarnessCore
import SwiftUI

struct WorkPlanEditorView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var editorTarget: WorkItemEditorTarget?
    @State private var pendingRemoval: WorkItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.project.workItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(store.project.workItems.enumerated()), id: \.element.id) { index, item in
                            WorkPlanEditorRow(
                                item: item,
                                canMoveUp: index > 0,
                                canMoveDown: index < store.project.workItems.count - 1,
                                onStatusChange: { store.setWorkItemStatus($0, for: item.id) },
                                onMoveUp: { store.moveWorkItem(item.id, by: -1) },
                                onMoveDown: { store.moveWorkItem(item.id, by: 1) },
                                onEdit: { editorTarget = .edit(item) },
                                onRemove: { pendingRemoval = item }
                            )
                            if index < store.project.workItems.count - 1 {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                    .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(.quaternary))
                    .padding(20)
                }
            }
        }
        .frame(width: 650, height: 560)
        .sheet(item: $editorTarget) { target in
            WorkItemFormView(target: target) { draft in
                if let itemID = target.workItemID {
                    return store.updateWorkItem(itemID, from: draft)
                }
                return store.addWorkItem(draft)
            }
        }
        .alert(
            "作業項目を削除しますか？",
            isPresented: removalBinding,
            presenting: pendingRemoval
        ) { item in
            Button("キャンセル", role: .cancel) { pendingRemoval = nil }
            Button("削除", role: .destructive) {
                store.removeWorkItem(item.id)
                pendingRemoval = nil
            }
        } message: { item in
            Text("「\(item.title)」を制作計画から削除します。ソースファイルは変更しません。")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("制作計画")
                    .font(.harness(.title2, weight: .bold))
                Text("作業の順序と状態を整理します。変更はプロジェクト記憶へ保存されます。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editorTarget = .add
            } label: {
                Label("作業を追加", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Button("完了") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.harness(size: 38, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("制作計画はまだありません")
                .font(.harness(.headline))
            Button("最初の作業を追加") { editorTarget = .add }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )
    }
}

private struct WorkPlanEditorRow: View {
    let item: WorkItem
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onStatusChange: (WorkStatus) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(WorkStatus.allCases) { status in
                    Button {
                        onStatusChange(status)
                    } label: {
                        Label(status.displayName, systemImage: status.symbol)
                    }
                }
            } label: {
                Label(item.status.displayName, systemImage: item.status.symbol)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 128)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.harness(.subheadline, weight: .semibold))
                Text(item.detail.isEmpty ? "詳細はありません" : item.detail)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()

            HStack(spacing: 5) {
                Button(action: onMoveUp) { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp)
                    .help("上へ移動")
                Button(action: onMoveDown) { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown)
                    .help("下へ移動")
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .help("編集")
                Button(action: onRemove) { Image(systemName: "trash") }
                    .foregroundStyle(.red)
                    .help("削除")
            }
            .buttonStyle(.borderless)
        }
        .padding(13)
    }
}

private struct WorkItemEditorTarget: Identifiable {
    let id = UUID()
    let workItemID: UUID?
    let draft: WorkItemDraft

    static let add = WorkItemEditorTarget(workItemID: nil, draft: WorkItemDraft())

    static func edit(_ item: WorkItem) -> WorkItemEditorTarget {
        WorkItemEditorTarget(workItemID: item.id, draft: WorkItemDraft(item: item))
    }
}

private struct WorkItemFormView: View {
    let target: WorkItemEditorTarget
    let onSave: (WorkItemDraft) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkItemDraft

    init(target: WorkItemEditorTarget, onSave: @escaping (WorkItemDraft) -> Bool) {
        self.target = target
        self.onSave = onSave
        _draft = State(initialValue: target.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(target.workItemID == nil ? "作業を追加" : "作業を編集")
                .font(.harness(.title2, weight: .bold))

            VStack(alignment: .leading, spacing: 7) {
                Text("名前").font(.harness(.caption, weight: .semibold))
                TextField("例: 画面構成を決める", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("詳細").font(.harness(.caption, weight: .semibold))
                TextField("完了条件や注意点", text: $draft.detail, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            Picker("状態", selection: $draft.status) {
                ForEach(WorkStatus.allCases) { status in
                    Text(status.displayName).tag(status)
                }
            }

            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                Button("保存") {
                    if onSave(draft) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

private extension WorkStatus {
    var displayName: String {
        switch self {
        case .completed: "完了"
        case .active: "進行中"
        case .pending: "未着手"
        case .needsAttention: "確認待ち"
        }
    }

    var symbol: String {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .active: "circle.dotted"
        case .pending: "circle"
        case .needsAttention: "exclamationmark.circle.fill"
        }
    }
}
