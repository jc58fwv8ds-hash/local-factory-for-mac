import AppKit
import HarnessCore
import SwiftUI

struct AppleAppTile: View {
    let app: InstallableAppleApp
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    icon
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.harness(.title3))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary.opacity(0.45))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.displayName)
                        .font(.harness(.title3, weight: .bold))
                        .lineLimit(1)
                    Text(app.source.projectName)
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    ForEach(app.supportedPlatforms, id: \.self) { platform in
                        PlatformBadge(platform: platform)
                    }
                }
                signingStatus
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 245, alignment: .leading)
            .background(.background.opacity(isSelected ? 0.94 : 0.76), in: tileShape)
            .overlay {
                tileShape.stroke(
                    isSelected ? Color.accentColor.opacity(0.72) : Color.secondary.opacity(0.14),
                    lineWidth: isSelected ? 2 : 1
                )
            }
            .shadow(
                color: .black.opacity(isSelected ? 0.09 : 0.035),
                radius: isSelected ? 18 : 8,
                y: isSelected ? 7 : 3
            )
            .contentShape(tileShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(app.displayName)、\(app.supportedPlatforms.map(\.displayName).joined(separator: "、"))対応")
        .accessibilityIdentifier(HarnessAccessibilityID.appTile(app.id))
    }

    @ViewBuilder
    private var icon: some View {
        if let data = app.iconData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.16)))
                .shadow(color: .black.opacity(0.14), radius: 9, y: 4)
                .frame(width: 76, height: 76)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.58)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: app.configuration(for: .appleWatch) != nil ? "applewatch" : "apps.iphone")
                    .font(.harness(size: 30, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 76, height: 76)
            .shadow(color: Color.accentColor.opacity(0.22), radius: 9, y: 4)
        }
    }

    private var signingStatus: some View {
        Label(
            app.needsSigningSetup ? "無料署名の設定が必要" : "インストール準備済み",
            systemImage: app.needsSigningSetup ? "person.badge.key" : "checkmark.seal.fill"
        )
        .font(.harness(.caption2, weight: .semibold))
        .foregroundStyle(app.needsSigningSetup ? .orange : .green)
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }
}

private struct PlatformBadge: View {
    let platform: AppleAppPlatform

    var body: some View {
        Label(
            platform.displayName,
            systemImage: platform == .iPhone ? "iphone.gen3" : "applewatch"
        )
        .font(.harness(.caption2, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.09), in: Capsule())
    }
}
