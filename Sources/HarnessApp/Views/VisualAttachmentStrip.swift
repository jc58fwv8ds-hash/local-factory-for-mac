import HarnessCore
import SwiftUI

struct VisualAttachmentStrip: View {
    let session: VisualAttachmentSession
    let remove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !session.items.isEmpty || session.isImporting {
                ScrollView(.horizontal) {
                    HStack(spacing: 9) {
                        ForEach(session.items) { item in
                            attachment(item)
                        }
                        if session.isImporting {
                            VStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("文字も確認中")
                                    .font(.harness(.caption2))
                                    .foregroundStyle(.secondary)
                            }
                                .frame(width: 78, height: 54)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.harness(.caption2))
                    .foregroundStyle(.orange)
            } else if !session.items.isEmpty {
                Text("画像はMac内の選択モデルだけに渡し、応答後に入力欄から外れます")
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func attachment(_ item: VisualAttachmentItem) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: item.preview)
                .resizable()
                .scaledToFill()
                .frame(width: 54, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.descriptor.displayName)
                    .font(.harness(.caption, weight: .semibold))
                    .lineLimit(1)
                Text("\(item.descriptor.pixelWidth)×\(item.descriptor.pixelHeight)")
                    .font(.harness(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
                switch item.textInspection {
                case .found(let transcript):
                    inspectionLabel("文字を\(transcript.lines.count)行確認", color: .green)
                case .noText:
                    inspectionLabel("文字なし", color: .secondary)
                case .unavailable:
                    inspectionLabel("文字確認なし", color: .orange)
                }
            }
            Button {
                remove(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("この画像を外す")
            .accessibilityIdentifier(HarnessAccessibilityID.commandImageRemove(item.id))
        }
        .padding(6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
    }

    private func inspectionLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.harness(.caption2))
            .foregroundStyle(color)
    }
}
