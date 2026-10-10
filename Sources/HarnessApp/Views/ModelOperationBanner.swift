import SwiftUI

struct ModelOperationBanner: View {
    @Bindable var manager: ModelManagerStore

    var body: some View {
        if manager.isInstalling, let message = manager.operationMessage {
            HStack(spacing: 12) {
                progressIndicator
                VStack(alignment: .leading, spacing: 3) {
                    Text(message)
                        .font(.harness(.subheadline, weight: .semibold))
                    Text(progressDescription)
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if manager.canStopInstallation {
                    Button("停止") { manager.stopInstallation() }
                        .controlSize(.small)
                }
            }
            .padding(14)
            .background(
                Color.accentColor.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 13)
            )
        } else if let error = manager.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.harness(.caption))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    manager.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(
                .orange.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 13)
            )
        } else if let message = manager.operationMessage {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.harness(.caption, weight: .medium))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if let fraction = manager.acquisitionProgress?.fraction {
            ZStack {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                Text("\(Int(fraction * 100))")
                    .font(.harness(size: 8, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 30, height: 30)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var progressDescription: String {
        manager.acquisitionProgress?.status
            ?? "ダウンロード中も他のプロジェクト情報は確認できます。"
    }
}
