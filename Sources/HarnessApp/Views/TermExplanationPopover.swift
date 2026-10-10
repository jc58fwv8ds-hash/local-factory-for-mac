import SwiftUI

struct TermExplanationPopover: View {
    @Bindable var display: TermExplanationDisplay
    let onHover: (Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.book.closed")
                    .foregroundStyle(Color.accentColor)
                Text(display.word)
                    .font(.harness(.headline))
                    .lineLimit(2)
                    .accessibilityIdentifier(HarnessAccessibilityID.termExplanation)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("解説を閉じる")
                    .accessibilityLabel("解説を閉じる")
            }
            HStack(alignment: .top, spacing: 8) {
                if display.isLoading { ProgressView().controlSize(.small) }
                Text(display.body)
                    .font(.harness(.body))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("この文章での意味 · ローカルAIの解説は目安です")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .onHover(perform: onHover)
    }
}
