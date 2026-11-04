import HarnessCore
import SwiftUI

/// One chat or project in the sidebar. It can be deleted from here (2026-11-04, the user: a chat could not be deleted): the
/// bin that appears under the pointer, or the row's menu, after a question. It goes to Local Factory's trash, not out of reach.
struct ProjectSidebarRow: View {
    let record: ProjectRecord
    let isSelected: Bool
    let action: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false
    @State private var isConfirming = false

    var body: some View {
        // The bin sits beside the row's button, not inside it (2026-11-04: nested, pressing the row through accessibility
        // pressed the bin).
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(isSelected ? 0.2 : 0.1))
                        .overlay {
                            Image(systemName: record.origin == .imported ? "folder.fill" : "hammer.fill")
                                .font(.harness(.caption))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 31, height: 31)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.project.name)
                            .font(.harness(.subheadline, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        Text(record.project.stage.rawValue)
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(HarnessAccessibilityID.sidebarProject(record.id))

            if isHovering || isSelected {
                Button { isConfirming = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("削除")
                    .accessibilityLabel("「\(record.project.name)」を削除")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("削除", systemImage: "trash", role: .destructive) { isConfirming = true }
        }
        .confirmationDialog("「\(record.project.name)」を削除しますか？", isPresented: $isConfirming) {
            Button("削除", role: .destructive, action: onDelete)
            Button("やめる", role: .cancel) {}
        } message: {
            Text("サイドバーの下の「ゴミ箱」へ移します。そこから元に戻せます。")
        }
    }
}

/// What was deleted from the sidebar, in the same mode: put back or removed for good (2026-11-04: chat mode had no way to
/// the trash, so a deleted chat could not be found).
struct SidebarTrashSection: View {
    @Bindable var store: WorkspaceStore
    @State private var isOpen = false
    @State private var deleting: ProjectRecord?

    private var records: [ProjectRecord] {
        store.library.trashedRecords.filter { $0.effectiveKind == store.workspaceMode.kind }
    }

    var body: some View {
        if !records.isEmpty {
            // The whole row opens it (2026-11-04: a DisclosureGroup opens only from its small triangle on the Mac, so clicking
            // 「ゴミ箱」 did nothing).
            VStack(alignment: .leading, spacing: 4) {
                Button { isOpen.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right").frame(width: 12)
                        Text("ゴミ箱(\(records.count))")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                if isOpen {
                    ForEach(records) { record in
                        HStack(spacing: 6) {
                            Text(record.project.name).lineLimit(1)
                            Spacer()
                            Button("戻す") { store.restoreProject(record.id) }.buttonStyle(.borderless)
                            Button("完全に削除", role: .destructive) { deleting = record }.buttonStyle(.borderless)
                        }
                        .padding(.leading, 16)
                    }
                }
            }
            .font(.harness(.caption))
            .padding(.horizontal, 6)
            .alert("完全に削除しますか?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { record in
                Button("キャンセル", role: .cancel) {}
                Button("完全に削除", role: .destructive) { store.deleteProjectCompletely(record.id) }
            } message: { record in
                Text("「\(record.project.name)」の会話と、その中で作った画像・動画を消します。元に戻せません。つないだフォルダの中身は消しません。")
            }
        }
    }
}
