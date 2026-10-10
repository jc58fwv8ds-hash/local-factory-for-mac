import HarnessCore
import SwiftUI

enum ProjectLibraryScope: String, CaseIterable, Identifiable {
    case all = "すべて"
    case active = "制作中"
    case archived = "アーカイブ"
    case trashed = "ゴミ箱"

    var id: String { rawValue }

    var lifecycle: ProjectLifecycle? {
        switch self {
        case .all: nil
        case .active: .active
        case .archived: .archived
        case .trashed: .trashed
        }
    }
}

struct ProjectLibraryHeader: View {
    let activeCount: Int
    let archivedCount: Int
    let trashedCount: Int
    let onImport: () -> Void
    let onCreate: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                Text("プロジェクト")
                    .font(.harness(size: 30, weight: .bold))
                    .accessibilityIdentifier(HarnessAccessibilityID.projectLibrary)
                Text("アイデア、制作中、休止中の仕事をひとつの場所で管理します。")
                    .font(.harness(.subheadline))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ProjectCountBadge(title: "制作中", count: activeCount, color: .accentColor)
                    ProjectCountBadge(title: "保管", count: archivedCount, color: .blue)
                    if trashedCount > 0 {
                        ProjectCountBadge(title: "ゴミ箱", count: trashedCount, color: .secondary)
                    }
                }
            }
            Spacer()
            Button(action: onImport) {
                Label("既存フォルダを追加", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(HarnessAccessibilityID.projectImport)
            Button(action: onCreate) {
                Label("新規プロジェクト", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(HarnessAccessibilityID.projectCreate)
        }
    }
}

private struct ProjectCountBadge: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        Text("\(title) \(count)")
            .font(.harness(.caption2, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.09), in: Capsule())
    }
}

struct ProjectLibraryControls: View {
    @Binding var searchText: String
    @Binding var scope: ProjectLibraryScope
    @Binding var sort: ProjectLibrarySort

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("プロジェクトを検索", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier(HarnessAccessibilityID.projectSearch)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("検索を消去")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
            .frame(maxWidth: 330)

            Picker("表示", selection: $scope) {
                ForEach(ProjectLibraryScope.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 450)

            Spacer()

            Menu {
                Picker("並び順", selection: $sort) {
                    ForEach(ProjectLibrarySort.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } label: {
                Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.quaternary))
    }
}

struct WorkspaceNoticeBanner: View {
    let notice: WorkspaceNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(notice.message)
                .font(.harness(.subheadline, weight: .medium))
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("通知を閉じる")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(color.opacity(0.18)))
    }

    private var color: Color {
        switch notice.kind {
        case .success: .green
        case .information: .blue
        case .error: .red
        }
    }

    private var symbol: String {
        switch notice.kind {
        case .success: "checkmark.circle.fill"
        case .information: "info.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

struct ProjectSectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.harness(.headline))
            Text(subtitle).font(.harness(.caption)).foregroundStyle(.secondary)
        }
    }
}

struct ProjectLibraryEmptyState: View {
    let hasSearch: Bool
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: hasSearch ? "magnifyingglass" : "square.stack.3d.up")
                .font(.harness(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(hasSearch ? "一致するプロジェクトがありません" : "この分類にプロジェクトはありません")
                .font(.harness(.headline))
            Text(hasSearch ? "検索語や表示分類を変えてみてください。" : "新しいアイデアから制作を始められます。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            if !hasSearch {
                Button("新規プロジェクトを作成", action: onCreate)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
    }
}
