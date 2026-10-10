import HarnessCore
import SwiftUI

struct RecentProjectActivitySection: View {
    let events: [ActivityEvent]
    @Binding var showsDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("最近の動き")
                    .font(.harness(.subheadline, weight: .semibold))
                Spacer()
                Button(showsDetails ? "閉じる" : "詳細") {
                    showsDetails.toggle()
                }
                .buttonStyle(.plain)
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            }

            ForEach(events.prefix(showsDetails ? 8 : 4)) { event in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(for: event.kind))
                        .foregroundStyle(color(for: event.kind))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title)
                            .font(.harness(.caption, weight: .semibold))
                        Text(event.detail)
                            .font(.harness(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(showsDetails ? 5 : 2)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func symbol(for kind: ActivityKind) -> String {
        switch kind {
        case .information: "info.circle.fill"
        case .change: "pencil.circle.fill"
        case .verification: "checkmark.seal.fill"
        case .instruction: "text.bubble.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: ActivityKind) -> Color {
        switch kind {
        case .information: .blue
        case .change: .accentColor
        case .verification: .green
        case .instruction: .accentColor
        case .warning: .orange
        }
    }
}
