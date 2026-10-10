import HarnessCore
import SwiftUI

struct SourceChangeNotice: View {
    let summary: SourceChangeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("ソース変更あり", systemImage: "arrow.triangle.2.circlepath")
                .font(.harness(.caption, weight: .semibold))
                .foregroundStyle(.orange)
            Text(summary.summaryText)
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
            ForEach(summary.samplePaths.prefix(3), id: \.self) { path in
                Text(path)
                    .font(.harness(.caption2).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if summary.samplePaths.count > 3 {
                Text("ほか \(summary.samplePaths.count - 3) 件")
                    .font(.harness(.caption2))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
