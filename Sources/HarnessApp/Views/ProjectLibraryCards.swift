import HarnessCore
import SwiftUI

struct ActiveProjectCard: View {
    let record: ProjectRecord
    let isSelected: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onArchive: () -> Void
    let onTrash: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 15) {
                cardHeader
                projectDescription
                progressSummary
                ProgressView(value: record.project.progress).tint(Color.accentColor)
            }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 17))
            .overlay {
                RoundedRectangle(cornerRadius: 17)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.16))
            }
        }
        .buttonStyle(.plain)
        .contextMenu { projectMenu }
    }

    private var cardHeader: some View {
        HStack {
            Image(systemName: record.origin == .imported ? "folder.fill" : "hammer.fill")
                .font(.harness(.title3))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            if record.origin == .imported {
                CompactSourceHealthBadge(inspection: record.sourceInspection)
            }
            Spacer()
            if isSelected {
                Text("選択中")
                    .font(.harness(.caption2, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
            Menu { projectMenu } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var projectDescription: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.project.name).font(.harness(.title3, weight: .bold)).lineLimit(1)
            Text(record.project.summary.isEmpty ? "説明はまだありません" : record.project.summary)
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(minHeight: 32, alignment: .topLeading)
        }
    }

    private var progressSummary: some View {
        HStack {
            Label(record.project.stage.rawValue, systemImage: "flag.fill")
            Spacer()
            Text("\(Int(record.project.progress * 100))%").monospacedDigit()
        }
        .font(.harness(.caption, weight: .medium))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var projectMenu: some View {
        Button("開く", action: onOpen)
        Button("プロジェクト情報を編集", action: onEdit)
        Button("アーカイブ", action: onArchive)
        Divider()
        Button("ゴミ箱へ移動", role: .destructive, action: onTrash)
    }
}

private struct CompactSourceHealthBadge: View {
    let inspection: SourceInspection?

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.harness(.caption2, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.08), in: Capsule())
    }

    private var title: String {
        switch inspection?.health {
        case .healthy: "ソース確認済み"
        case .limited: "一部確認"
        case .missing: "ソース不明"
        case .unreadable: "読取不可"
        case nil: "未診断"
        }
    }

    private var symbol: String {
        switch inspection?.health {
        case .healthy: "checkmark.circle.fill"
        case .limited: "ellipsis.circle.fill"
        case .missing: "questionmark.folder.fill"
        case .unreadable: "exclamationmark.triangle.fill"
        case nil: "clock"
        }
    }

    private var color: Color {
        switch inspection?.health {
        case .healthy: .green
        case .limited: .orange
        case .missing, .unreadable: .red
        case nil: .secondary
        }
    }
}

struct LifecycleProjectRow: View {
    let record: ProjectRecord
    let onRestore: () -> Void
    let onTrash: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: record.lifecycle == .trashed ? "trash" : "archivebox")
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.project.name).font(.harness(.subheadline, weight: .semibold))
                Text(record.sourceLocation ?? record.project.summary)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("復元", action: onRestore)
                .buttonStyle(.bordered)
                .controlSize(.small)
            if record.lifecycle == .archived {
                Button("ゴミ箱へ", role: .destructive, action: onTrash)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            } else {
                Button("一覧から削除", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
