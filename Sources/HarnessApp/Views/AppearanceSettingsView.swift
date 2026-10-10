import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        @Bindable var appearance = appearance

        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    modeSection(mode: $appearance.mode)
                    paletteSection(selectedTheme: $appearance.theme)
                    typographySection
                    appearancePreview
                }
                .padding(22)
            }
        }
        .frame(width: 620, height: 760)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("カラーと外観")
                    .font(.harness(.title2, weight: .bold))
                Text("作業内容は変えず、Local Factory全体の印象を選べます。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("完了") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(22)
    }

    private func modeSection(
        mode: Binding<HarnessAppearanceMode>
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("明るさ", systemImage: "circle.lefthalf.filled")
                .font(.harness(.headline))
            Picker("明るさ", selection: mode) {
                ForEach(HarnessAppearanceMode.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func paletteSection(
        selectedTheme: Binding<HarnessColorTheme>
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("カラーテーマ", systemImage: "paintpalette.fill")
                .font(.harness(.headline))

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(HarnessColorTheme.allCases) { theme in
                    ThemeChoiceCard(
                        theme: theme,
                        isSelected: selectedTheme.wrappedValue == theme,
                        action: { selectedTheme.wrappedValue = theme }
                    )
                }
            }
        }
    }

    private var appearancePreview: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("プレビュー", systemImage: "rectangle.inset.filled")
                .font(.harness(.headline))

            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 13)
                    .fill(
                        LinearGradient(
                            colors: [appearance.theme.companionColor, appearance.theme.accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: appearance.theme.symbol)
                            .font(.harness(.title, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 70, height: 70)

                VStack(alignment: .leading, spacing: 6) {
                    Text(appearance.theme.displayName)
                        .font(.harness(.headline))
                    Text(appearance.theme.detail)
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                    ProgressView(value: 0.68)
                        .tint(appearance.theme.accentColor)
                }
                Spacer()
                Button("アクション") {}
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.quaternary))
        }
    }

    private var typographySection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("タイポグラフィ", systemImage: "textformat")
                .font(.harness(.headline))

            HStack(spacing: 12) {
                typographySample(
                    sample: "Local Factory for Mac",
                    family: "Apple Garamond",
                    isAvailable: HarnessTypography.usesAppleGaramond(),
                    fallbackName: HarnessTypography.resolvedEnglishFontName()
                )
                typographySample(
                    sample: "制作を、もっと自然に。",
                    family: "ヒラギノ角ゴ",
                    isAvailable: true,
                    fallbackName: "HiraginoSans-W3"
                )
            }
            Text("コード、差分、検証ログは読みやすい等幅フォントを維持します。")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
        }
    }

    private func typographySample(
        sample: String,
        family: String,
        isAvailable: Bool,
        fallbackName: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(sample)
                .font(.harness(.subheadline, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 5) {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "arrow.trianglehead.2.clockwise")
                Text(
                    isAvailable
                        ? "\(family)・\(fallbackName ?? family)"
                        : "\(family)未導入・\(fallbackName ?? "標準セリフ")で代替"
                )
            }
            .font(.harness(.caption2))
            .foregroundStyle(isAvailable ? Color.secondary : Color.orange)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary))
    }
}

private struct ThemeChoiceCard: View {
    let theme: HarnessColorTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(theme.companionColor)
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 22, height: 22)
                        .offset(x: 8, y: 7)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(theme.displayName)
                        .font(.harness(.subheadline, weight: .semibold))
                    Text(theme.detail)
                        .font(.harness(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(12)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.12))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
