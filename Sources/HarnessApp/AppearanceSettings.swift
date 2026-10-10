import Observation
import SwiftUI

enum HarnessColorTheme: String, CaseIterable, Identifiable {
    case centurion
    case sapphire
    case amethyst
    case emerald
    case ember
    case rose

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .centurion: "Centurion"
        case .sapphire: "Sapphire"
        case .amethyst: "Amethyst"
        case .emerald: "Emerald"
        case .ember: "Ember"
        case .rose: "Rose"
        }
    }

    var detail: String {
        switch self {
        case .centurion: "黒とシャンパンゴールド"
        case .sapphire: "落ち着いた深いブルー"
        case .amethyst: "創造性を感じるパープル"
        case .emerald: "集中しやすいグリーン"
        case .ember: "温かく活発なオレンジ"
        case .rose: "柔らかなローズピンク"
        }
    }

    var accentColor: Color {
        switch self {
        case .centurion: Color(red: 0.72, green: 0.55, blue: 0.30)
        case .sapphire: Color(red: 0.16, green: 0.43, blue: 0.88)
        case .amethyst: Color(red: 0.55, green: 0.28, blue: 0.84)
        case .emerald: Color(red: 0.10, green: 0.58, blue: 0.42)
        case .ember: Color(red: 0.92, green: 0.39, blue: 0.16)
        case .rose: Color(red: 0.86, green: 0.28, blue: 0.48)
        }
    }

    var companionColor: Color {
        switch self {
        case .centurion: Color(red: 0.15, green: 0.15, blue: 0.16)
        case .sapphire: Color(red: 0.16, green: 0.73, blue: 0.88)
        case .amethyst: Color(red: 0.88, green: 0.28, blue: 0.67)
        case .emerald: Color(red: 0.42, green: 0.78, blue: 0.38)
        case .ember: Color(red: 0.96, green: 0.68, blue: 0.18)
        case .rose: Color(red: 0.96, green: 0.52, blue: 0.63)
        }
    }

    var symbol: String {
        switch self {
        case .centurion: "creditcard.fill"
        case .sapphire: "drop.fill"
        case .amethyst: "sparkles"
        case .emerald: "leaf.fill"
        case .ember: "flame.fill"
        case .rose: "heart.fill"
        }
    }
}

enum HarnessAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "システム"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
@Observable
final class AppearanceSettings {
    var theme: HarnessColorTheme {
        didSet { defaults.set(theme.rawValue, forKey: Self.themeKey) }
    }

    var mode: HarnessAppearanceMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.theme = HarnessColorTheme(
            rawValue: defaults.string(forKey: Self.themeKey) ?? ""
        ) ?? .centurion
        self.mode = HarnessAppearanceMode(
            rawValue: defaults.string(forKey: Self.modeKey) ?? ""
        ) ?? .system
    }

    private static let themeKey = "appearance.theme"
    private static let modeKey = "appearance.mode"
}
