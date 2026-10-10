import HarnessCore
import SwiftUI

struct StageRail: View {
    let current: ProjectStage

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ProjectStage.allCases) { stage in
                let completed = stage.ordinal < current.ordinal
                let selected = stage == current

                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(completed || selected ? Color.accentColor : Color.secondary.opacity(0.14))
                        if completed {
                            Image(systemName: "checkmark")
                                .font(.harness(.caption2, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(stage.ordinal + 1)")
                                .font(.harness(.caption2, weight: .bold))
                                .foregroundStyle(selected ? .white : .secondary)
                        }
                    }
                    .frame(width: 24, height: 24)

                    Text(stage.rawValue)
                        .font(.harness(.caption, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                }

                if stage != ProjectStage.allCases.last {
                    Rectangle()
                        .fill(stage.ordinal < current.ordinal ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.13))
                        .frame(height: 2)
                        .padding(.horizontal, 9)
                }
            }
        }
        .padding(15)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.quaternary))
    }
}

struct WorkItemRow: View {
    let item: WorkItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.harness(size: 16, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.harness(.subheadline, weight: .medium))
                Text(item.detail)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.status == .active {
                ProgressView()
                    .controlSize(.small)
            }
            if item.status == .needsAttention {
                Text("確認待ち")
                    .font(.harness(.caption2, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.1), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var statusSymbol: String {
        switch item.status {
        case .completed: "checkmark.circle.fill"
        case .active: "circle.dotted"
        case .pending: "circle"
        case .needsAttention: "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: .green
        case .active: .accentColor
        case .pending: .secondary.opacity(0.5)
        case .needsAttention: .orange
        }
    }
}
