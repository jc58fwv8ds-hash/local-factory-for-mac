import SwiftUI

struct ProductPreview: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(.red.opacity(0.75))
                    Circle().fill(.yellow.opacity(0.8))
                    Circle().fill(.green.opacity(0.75))
                }
                .frame(width: 48)

                Spacer()
                Label("デザインプレビュー", systemImage: "rectangle.inset.filled")
                    .font(.harness(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Label("モックプレビュー", systemImage: "rectangle.dashed")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(.ultraThinMaterial)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    Label("昨日の記憶", systemImage: "clock.arrow.circlepath")
                        .font(.harness(.headline))

                    MemoryRow(time: "09:10", title: "朝の計画", importance: 0.65)
                    MemoryRow(time: "10:42", title: "プロジェクトの方針を決定", importance: 0.98)
                    MemoryRow(time: "15:20", title: "Personal Memoryの設計", importance: 0.91)
                    MemoryRow(time: "19:05", title: "帰宅・移動", importance: 0.16)
                    Spacer()
                }
                .padding(20)
                .frame(width: 242)
                .background(Color.primary.opacity(0.025))

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Personal Memoryの設計")
                                .font(.harness(.title3, weight: .bold))
                            Text("15:20–15:48 ・ 重要度 91")
                                .font(.harness(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "waveform.circle.fill")
                            .font(.harness(size: 34))
                            .foregroundStyle(Color.accentColor)
                    }

                    Text("Apple Watchを記録端末、iPhoneを中継、Macを解析と長期記憶の中枢にする構成を検討しました。原音から文字起こしと重要度判定を行い、翌朝までに読み返せる一日の記録へ編集します。")
                        .font(.harness(.subheadline))
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)

                    HStack(spacing: 8) {
                        PreviewTag(text: "設計判断", color: .accentColor)
                        PreviewTag(text: "重要", color: .orange)
                        PreviewTag(text: "ローカル処理", color: .blue)
                    }

                    Spacer()

                    HStack {
                        Label("元の音声を確認", systemImage: "headphones")
                        Spacer()
                        Label("全文", systemImage: "doc.text")
                    }
                    .font(.harness(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .padding(22)
            }
            .frame(height: 298)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.quaternary))
        .shadow(color: .black.opacity(0.06), radius: 14, y: 7)
    }
}

private struct MemoryRow: View {
    let time: String
    let title: String
    let importance: Double

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(time)
                .font(.harness(.caption).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.harness(.subheadline, weight: .medium))
                    .lineLimit(2)
                ProgressView(value: importance)
                    .tint(importance > 0.8 ? Color.accentColor : Color.secondary)
            }
        }
    }
}

private struct PreviewTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.harness(.caption2, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.1), in: Capsule())
    }
}
