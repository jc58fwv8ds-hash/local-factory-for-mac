import Foundation

public enum VisualAnalysisPurpose: String, Codable, Equatable, Sendable {
    case generalReference
    case screenDetail
    case appIcon
}

public enum VisualAnalysisPass: Equatable, Sendable {
    case nativeResolution
    case overview(maxPixelDimension: Int)
    case focusedRegions(maximumCount: Int)
    case iconPreview(pixelDimension: Int)
}

public struct VisualAnalysisPlan: Equatable, Sendable {
    public let purpose: VisualAnalysisPurpose
    public let passes: [VisualAnalysisPass]
    public let preservesOriginalPixels: Bool

    public init(
        purpose: VisualAnalysisPurpose,
        passes: [VisualAnalysisPass],
        preservesOriginalPixels: Bool
    ) {
        self.purpose = purpose
        self.passes = passes
        self.preservesOriginalPixels = preservesOriginalPixels
    }
}

public enum VisualAnalysisPolicy {
    /// High-resolution references stay intact. The model first surveys the whole image,
    /// then narrows its attention instead of receiving one destructive downsample.
    public static func plan(
        for attachment: VisualAttachmentDescriptor,
        purpose: VisualAnalysisPurpose
    ) -> VisualAnalysisPlan {
        switch purpose {
        case .appIcon:
            VisualAnalysisPlan(
                purpose: purpose,
                passes: [
                    .nativeResolution,
                    .iconPreview(pixelDimension: 256),
                    .iconPreview(pixelDimension: 64),
                    .iconPreview(pixelDimension: 32),
                    .iconPreview(pixelDimension: 16)
                ],
                preservesOriginalPixels: true
            )
        case .screenDetail:
            VisualAnalysisPlan(
                purpose: purpose,
                passes: max(attachment.pixelWidth, attachment.pixelHeight) > 2_048
                    ? [.overview(maxPixelDimension: 2_048), .focusedRegions(maximumCount: 6)]
                    : [.nativeResolution],
                preservesOriginalPixels: true
            )
        case .generalReference:
            VisualAnalysisPlan(
                purpose: purpose,
                passes: [.nativeResolution],
                preservesOriginalPixels: true
            )
        }
    }

    public static func instruction(for attachments: [VisualAttachmentDescriptor]) -> String {
        let hasScreen = attachments.contains {
            $0.source == .simulatorScreenshot || $0.pixelWidth > 2_048 || $0.pixelHeight > 2_048
        }
        guard hasScreen else {
            return "画像は原寸の情報を保って確認し、読めない細部は推測せず未確認と伝えてください。"
        }
        return """
        高解像度の画面は、まず全体の構成を確認し、その後に依頼と関係する細かな文字や部品へ範囲を絞ってください。
        全体の縮小表示だけで細部を断定せず、読めない箇所は位置と不確かさを示してください。
        """
    }
}
