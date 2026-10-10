import SwiftUI

/// The card under an analysis request: the result table computed by DuckDB, and the SQL that produced it.
struct AnalysisChangeCard: View {
    let change: AnalysisChange
    @State private var isShowingQuery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal")
                Text("集計").font(.harness(.subheadline, weight: .semibold))
                Spacer()
            }
            switch change.status {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("集計の方法を考えています。").font(.harness(.caption)).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.harness(.caption)).foregroundStyle(.secondary)
            case .ready:
                if let result = change.result {
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                            GridRow { ForEach(result.columns, id: \.self) { Text($0).font(.harness(.caption, weight: .semibold)) } }
                            Divider()
                            ForEach(Array(result.rows.prefix(50).enumerated()), id: \.offset) { _, row in
                                GridRow { ForEach(Array(row.enumerated()), id: \.offset) { Text($0.element).font(.harness(.caption).monospacedDigit()) } }
                            }
                        }
                    }
                    if result.rows.count > 50 {
                        Text("ほか \(result.rows.count - 50) 行").font(.harness(.caption2)).foregroundStyle(.secondary)
                    }
                    Text("数値は表のデータから DuckDB が計算したものです。").font(.harness(.caption2)).foregroundStyle(.secondary)
                }
                DisclosureGroup("集計に使った SQL", isExpanded: $isShowingQuery) {
                    Text(change.query).font(.harness(.caption2).monospaced()).textSelection(.enabled)
                }
                .font(.harness(.caption2))
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}
