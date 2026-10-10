import HarnessCore
import SwiftUI

struct CatalogCard: View {
    let entry: ModelCatalogEntry
    let assessment: ModelFitAssessment
    let isInstalled: Bool
    let isBusy: Bool
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.1))
                    .overlay {
                        Image(systemName: entry.isRecommended ? "brain.fill" : "hare.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 40, height: 40)
                Spacer()
                Text(fitTitle)
                        .font(.harness(.caption2, weight: .bold))
                        .foregroundStyle(fitColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(fitColor.opacity(0.1), in: Capsule())
            }

            Text(entry.displayName)
                .font(.harness(.subheadline, weight: .semibold))
            Text(entry.summary)
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(entry.parameterLabel) ・ 約\(entry.estimatedSizeGB.formatted())GB")
                .font(.harness(.caption2).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(fitDescription)
                .font(.harness(.caption2))
                .foregroundStyle(fitColor)
                .fixedSize(horizontal: false, vertical: true)

            if entry.isRecommended {
                Button(isInstalled ? "インストール済み" : "インストール", action: install)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isInstalled || isBusy)
            } else {
                Button(isInstalled ? "インストール済み" : "インストール", action: install)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isInstalled || isBusy)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 206, alignment: .topLeading)
        .managerCard()
    }

    private var fitTitle: String {
        switch assessment.level {
        case .suitable: "適合"
        case .constrained: "要注意"
        case .notRecommended: "非推奨"
        case .insufficientStorage: "容量不足"
        case .unknown: "未確認"
        }
    }

    private var fitDescription: String {
        switch assessment.level {
        case .suitable:
            "このMacで無理なく利用できる見込みです"
        case .constrained:
            "同時に使うアプリを減らすと安定します"
        case .notRecommended:
            "小さいモデルの利用を推奨します"
        case .insufficientStorage:
            "安全な取得に必要な空きがありません"
        case .unknown:
            "容量情報を確認してから導入してください"
        }
    }

    private var fitColor: Color {
        switch assessment.level {
        case .suitable: .green
        case .constrained: .orange
        case .notRecommended, .insufficientStorage: .red
        case .unknown: .secondary
        }
    }
}

struct InstalledModelRow: View {
    let model: InstalledModel
    let isSelected: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.transparent.fill")
                .font(.harness(.title3))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .font(.harness(.subheadline, weight: .medium))
                Text("\(model.runtime.rawValue) ・ \(model.sizeLabel)")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                if model.capabilities?.contains(.imageUnderstanding) == true {
                    Label("画像を確認できます", systemImage: "photo")
                        .font(.harness(.caption2))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Label("使用中", systemImage: "checkmark.circle.fill")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Button("使用する", action: select)
                    .controlSize(.small)
            }
            if model.runtime == .ollama {
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("モデルを削除")
            }
        }
        .padding(13)
    }
}

extension View {
    func managerCard() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}
