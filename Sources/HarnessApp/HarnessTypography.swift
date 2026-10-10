import AppKit
import SwiftUI

enum HarnessTextStyle {
    case title
    case title2
    case title3
    case headline
    case body
    case subheadline
    case caption
    case caption2

    var size: CGFloat {
        switch self {
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 13
        case .subheadline: 12
        case .caption: 11
        case .caption2: 10
        }
    }

    var defaultWeight: HarnessFontWeight {
        self == .headline ? .semibold : .regular
    }
}

enum HarnessFontWeight {
    case light
    case regular
    case medium
    case semibold
    case bold

    var appKitWeight: NSFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    var hiraginoName: String {
        switch self {
        case .light: "HiraginoSans-W2"
        case .regular: "HiraginoSans-W3"
        case .medium: "HiraginoSans-W4"
        case .semibold: "HiraginoSans-W5"
        case .bold: "HiraginoSans-W6"
        }
    }

    var appleGaramondCandidates: [String] {
        switch self {
        case .light: ["AppleGaramond-Light", "Apple Garamond Light"]
        case .regular, .medium: ["AppleGaramond", "Apple Garamond"]
        case .semibold, .bold: ["AppleGaramond-Bold", "Apple Garamond Bold"]
        }
    }
}

enum HarnessTypography {
    static func font(
        _ style: HarnessTextStyle,
        weight: HarnessFontWeight? = nil
    ) -> Font {
        font(size: style.size, weight: weight ?? style.defaultWeight)
    }

    static func font(
        size: CGFloat,
        weight: HarnessFontWeight = .regular
    ) -> Font {
        Font(resolvedFont(size: size, weight: weight))
    }

    static func usesAppleGaramond(weight: HarnessFontWeight = .regular) -> Bool {
        resolvedEnglishFontName(weight: weight)
            .localizedCaseInsensitiveContains("Garamond")
    }

    static func resolvedEnglishFontName(
        weight: HarnessFontWeight = .regular
    ) -> String {
        resolvedFont(size: 13, weight: weight).fontName
    }

    static func resolvedFont(
        size: CGFloat,
        weight: HarnessFontWeight
    ) -> NSFont {
        let latinDescriptor: NSFontDescriptor
        if let appleGaramondName = appleGaramondName(for: weight) {
            latinDescriptor = NSFontDescriptor(name: appleGaramondName, size: size)
        } else {
            let systemDescriptor = NSFont.systemFont(
                ofSize: size,
                weight: weight.appKitWeight
            ).fontDescriptor
            latinDescriptor = systemDescriptor.withDesign(.serif) ?? systemDescriptor
        }

        let japaneseDescriptor = NSFontDescriptor(
            name: weight.hiraginoName,
            size: size
        )
        let cascadedDescriptor = latinDescriptor.addingAttributes([
            .cascadeList: [japaneseDescriptor]
        ])
        return NSFont(descriptor: cascadedDescriptor, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight.appKitWeight)
    }

    private static func appleGaramondName(
        for weight: HarnessFontWeight
    ) -> String? {
        weight.appleGaramondCandidates.first {
            NSFont(name: $0, size: 13) != nil
        }
    }
}

extension Font {
    static func harness(
        _ style: HarnessTextStyle,
        weight: HarnessFontWeight? = nil
    ) -> Font {
        HarnessTypography.font(style, weight: weight)
    }

    static func harness(
        size: CGFloat,
        weight: HarnessFontWeight = .regular
    ) -> Font {
        HarnessTypography.font(size: size, weight: weight)
    }
}
