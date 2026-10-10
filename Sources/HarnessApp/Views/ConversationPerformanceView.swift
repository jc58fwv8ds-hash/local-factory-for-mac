import HarnessCore
import SwiftUI

struct ConversationPerformanceView: View {
    let performance: ConversationPerformance

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(performance.attempts.enumerated()), id: \.offset) { index, timing in
                    VStack(alignment: .leading, spacing: 4) {
                        if performance.attempts.count > 1 {
                            Text(index == 0 ? "最初の回答" : "考え直した回答")
                                .font(.harness(.caption, weight: .semibold))
                        }
                        LabeledContent("回答が出始めるまで", value: seconds(timing.firstContentSeconds))
                        LabeledContent("その後の受信", value: seconds(timing.receivingSeconds))
                        LabeledContent("AIへ渡した文章", value: "\(timing.promptCharacters)文字")
                        promptComposition(timing.promptComposition)
                    }
                }
                Text("この返答で実測した時間です。接続やモデルの読み込みも含みます。ソースの読み取り・保存時間は含まず、文字数はトークン数ではありません。内訳は本文を保存せず数だけ計測し、アプリを閉じると消えます。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.harness(.caption2))
            .padding(.top, 4)
        } label: {
            Text("この返答の待ち時間")
                .font(.harness(.caption))
                .accessibilityIdentifier(HarnessAccessibilityID.responsePerformance)
        }
        .foregroundStyle(.secondary)
    }

    private func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.1f秒", $0) } ?? "未計測"
    }

    @ViewBuilder
    private func promptComposition(_ composition: InferencePromptComposition) -> some View {
        Text("入力の内訳（\(composition.messageCount)件）")
            .font(.harness(.caption2, weight: .semibold))
        LabeledContent("Local Factoryの方針", value: "\(composition.systemCharacters)文字")
        LabeledContent("ユーザーの会話", value: "\(composition.userCharacters)文字")
        LabeledContent("過去のAI回答", value: "\(composition.assistantCharacters)文字")
        LabeledContent("ソース引用", value: "\(composition.sourceCharacters)文字")
        if composition.externalReviewCharacters > 0 {
            LabeledContent("外部レビュー引用", value: "\(composition.externalReviewCharacters)文字")
        }
    }
}
