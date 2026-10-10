import SwiftUI

enum RemoteDesign {
    static let minimumTapTarget: CGFloat = 44
    static let primaryButtonHeight: CGFloat = 50
    static let cardCornerRadius: CGFloat = 20
    static let pageSpacing: CGFloat = 20
    static let cardSpacing: CGFloat = 14
    static let pagePadding: CGFloat = 20
    static let maximumReadableWidth: CGFloat = 620
}

struct RemoteCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RemoteDesign.pagePadding)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(
                    cornerRadius: RemoteDesign.cardCornerRadius,
                    style: .continuous
                )
            )
    }
}

extension RemoteConnectionState {
    var tint: Color {
        switch self {
        case .connected: .green
        case .failed: .orange
        case .searching, .connecting: .blue
        case .idle: .secondary
        }
    }
}

extension RemoteInstructionStatus {
    var title: String {
        switch self {
        case .accepted: "受付済み"
        case .queued: "待機中"
        case .busy: "Harnessは処理中"
        case .unavailable: "受付準備中"
        case .rejected: "受付できませんでした"
        }
    }

    var systemImage: String {
        switch self {
        case .accepted: "checkmark.circle.fill"
        case .queued: "clock.fill"
        case .busy: "hourglass"
        case .unavailable: "pause.circle.fill"
        case .rejected: "exclamationmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .accepted: .green
        case .queued, .busy: .blue
        case .unavailable, .rejected: .orange
        }
    }
}
