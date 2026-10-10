import HarnessCore
import SwiftUI

struct FileDiffPreview: View {
    let proposal: FileChangeProposal

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DiffCountBadge(
                    title: "+\(proposal.summary.addedLineCount)",
                    color: .green
                )
                DiffCountBadge(
                    title: "−\(proposal.summary.removedLineCount)",
                    color: .red
                )
                Spacer()
                Text("保存前の差分")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(10)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(proposal.diffLines.enumerated()), id: \.offset) { _, line in
                        FileDiffRow(line: line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }
}

private struct FileDiffRow: View {
    let line: FileDiffLine

    var body: some View {
        HStack(spacing: 0) {
            lineNumber(line.oldLineNumber)
            lineNumber(line.newLineNumber)
            Text(prefix)
                .foregroundStyle(prefixColor)
                .frame(width: 22)
            Text(line.text.isEmpty ? " " : line.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 12)
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(minHeight: 20)
        .background(backgroundColor)
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 8)
            .background(.secondary.opacity(0.035))
    }

    private var prefix: String {
        switch line.kind {
        case .context: " "
        case .removal: "−"
        case .addition: "+"
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .context: .secondary
        case .removal: .red
        case .addition: .green
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .context: .clear
        case .removal: .red.opacity(0.09)
        case .addition: .green.opacity(0.09)
        }
    }
}

private struct DiffCountBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.harness(.caption, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
    }
}
