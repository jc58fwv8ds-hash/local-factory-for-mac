import HarnessCore
import SwiftUI

/// The mark of a model option with fewer safety limits (2026-10-19, the user's request: easy to tell apart). The words
/// come from the option's `badge` in the local catalog; the app only shows them, always in the same warning style.
struct PurposeBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.shield.fill")
            .font(.harness(.caption2, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.orange, in: Capsule())
            .accessibilityLabel("注意: \(text)")
    }
}

/// Next to the composer's purpose menu: the model the chosen purpose will use, with its mark when it has one.
struct PurposeModelChip: View {
    let purpose: ComposerPurpose
    let settings: PurposeModelSettings

    var body: some View {
        if let option = modelPurpose.flatMap(settings.chosen) {
            HStack(spacing: 5) {
                if let badge = option.badge { PurposeBadge(text: badge) }
                Text(option.label).font(.harness(.caption2)).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(option.note ?? option.label)
        }
    }

    private var modelPurpose: ModelPurpose? {
        switch purpose {
        case .conversation: nil
        case .writing: .writing
        case .image: .image
        case .video: .video
        }
    }
}
