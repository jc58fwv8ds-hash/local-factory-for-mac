import Foundation

public enum VisualAttachmentPolicyError: LocalizedError, Equatable, Sendable {
    case tooMany(maximum: Int)
    case emptyImage(String)
    case imageTooLarge(String, maximumBytes: Int)
    case batchTooLarge(maximumBytes: Int)
    case invalidDimensions(String)
    case excessiveDimensions(String)
    case invalidName
    case invalidContentHash(String)
    case duplicateContent(String)

    public var errorDescription: String? {
        switch self {
        case .tooMany(let maximum):
            "画像は一度に\(maximum)枚まで選べます。"
        case .emptyImage(let name):
            "\(name)には画像データがありません。"
        case .imageTooLarge(let name, let maximumBytes):
            "\(name)は大きすぎます。1枚\(Self.megabytes(maximumBytes))MB以内にしてください。"
        case .batchTooLarge(let maximumBytes):
            "画像の合計が大きすぎます。\(Self.megabytes(maximumBytes))MB以内にしてください。"
        case .invalidDimensions(let name):
            "\(name)の縦横サイズを確認できません。"
        case .excessiveDimensions(let name):
            "\(name)の解像度が高すぎます。縮小してから追加してください。"
        case .invalidName:
            "画像の名前を確認できません。"
        case .invalidContentHash(let name):
            "\(name)の内容確認情報が壊れています。もう一度追加してください。"
        case .duplicateContent(let name):
            "\(name)と同じ画像がすでに選ばれています。"
        }
    }

    private static func megabytes(_ bytes: Int) -> Int { bytes / 1_048_576 }
}

public enum VisualAttachmentPolicy {
    public static let maximumAttachmentCount = 4
    public static let maximumBytesPerImage = 20 * 1_048_576
    public static let maximumBatchBytes = 40 * 1_048_576
    public static let maximumPixelDimension = 16_384
    public static let maximumPixelCount = 40_000_000
    public static let maximumDisplayNameLength = 160

    public static func validationError(
        for attachments: [VisualAttachmentDescriptor]
    ) -> VisualAttachmentPolicyError? {
        guard attachments.count <= maximumAttachmentCount else {
            return .tooMany(maximum: maximumAttachmentCount)
        }

        var totalBytes = 0
        var hashes = Set<String>()
        for attachment in attachments {
            if let error = validationError(for: attachment) { return error }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(attachment.byteCount)
            guard !overflow, nextTotal <= maximumBatchBytes else {
                return .batchTooLarge(maximumBytes: maximumBatchBytes)
            }
            totalBytes = nextTotal
            guard hashes.insert(attachment.contentHash).inserted else {
                return .duplicateContent(attachment.displayName)
            }
        }
        return nil
    }

    public static func validationError(
        for attachment: VisualAttachmentDescriptor
    ) -> VisualAttachmentPolicyError? {
        let name = attachment.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maximumDisplayNameLength else { return .invalidName }
        guard attachment.byteCount > 0 else { return .emptyImage(name) }
        guard attachment.byteCount <= maximumBytesPerImage else {
            return .imageTooLarge(name, maximumBytes: maximumBytesPerImage)
        }
        guard attachment.pixelWidth > 0, attachment.pixelHeight > 0 else {
            return .invalidDimensions(name)
        }
        let (pixelCount, overflow) = attachment.pixelWidth.multipliedReportingOverflow(
            by: attachment.pixelHeight
        )
        guard !overflow,
              attachment.pixelWidth <= maximumPixelDimension,
              attachment.pixelHeight <= maximumPixelDimension,
              pixelCount <= maximumPixelCount else {
            return .excessiveDimensions(name)
        }
        guard VisualContentHash.isValidSHA256(attachment.contentHash) else {
            return .invalidContentHash(name)
        }
        return nil
    }

}
