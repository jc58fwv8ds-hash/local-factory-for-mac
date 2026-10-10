import HarnessCore
import SwiftUI

struct ValidationRevisionGuidanceView: View {
    let guidance: ValidationRevisionGuidance
    let reviewMode: CreationLoopReviewMode
    let onRequestExternalReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Local Factoryの修正ガイド", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.harness(.headline))
                .foregroundStyle(Color.accentColor)
            guidanceRow(title: "現状", content: guidance.currentState)
            guidanceRow(title: "こう修正する", content: guidance.proposedChange)
            guidanceRow(title: "得られる結果", content: guidance.expectedResult)

            if reviewMode == .chatGPTAssisted {
                Divider()
                Text("成果物と検査結果を確認してから通常ChatGPTへ渡し、別視点の修正案を加えられます。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                Button {
                    onRequestExternalReview()
                } label: {
                    Label("ChatGPTレビューを準備", systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.accentColor.opacity(0.18)))
    }

    private func guidanceRow(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.harness(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(content)
                .font(.harness(.body))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
