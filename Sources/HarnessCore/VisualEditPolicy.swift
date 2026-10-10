import Foundation

public enum VisualEditPolicyError: LocalizedError, Equatable, Sendable {
    case noOperations
    case tooManyOperations(maximum: Int)
    case invalidSourceHash
    case invalidTrimTolerance
    case invalidCrop
    case invalidResize
    case invalidTone
    case emptyGenerativeInstruction
    case generativeInstructionTooLong(maximum: Int)
    case multipleGenerativeOperations
    case generativeOperationMustBeLast

    public var errorDescription: String? {
        switch self {
        case .noOperations: "画像の変更内容がありません。"
        case .tooManyOperations(let maximum): "一度の画像編集は\(maximum)工程までです。"
        case .invalidSourceHash: "編集元の画像を確認できません。"
        case .invalidTrimTolerance: "余白判定の強さを確認してください。"
        case .invalidCrop: "切り抜く範囲を確認してください。"
        case .invalidResize: "画像の仕上がりサイズを確認してください。"
        case .invalidTone: "明るさや色味の指定を確認してください。"
        case .emptyGenerativeInstruction: "生成編集で変えたい内容を書いてください。"
        case .generativeInstructionTooLong(let maximum): "生成編集の指示は\(maximum)文字以内にしてください。"
        case .multipleGenerativeOperations: "生成を使う編集は一度に1工程までです。"
        case .generativeOperationMustBeLast: "生成編集は、切り抜きや色調整の後に行ってください。"
        }
    }
}

public enum VisualEditPolicy {
    public static let maximumOperationCount = 8
    public static let maximumGenerativeInstructionCharacters = 1_000
    public static let minimumOutputPixelDimension = 64
    public static let maximumOutputPixelDimension = 8_192

    public static func validationError(
        for recipe: VisualEditRecipe
    ) -> VisualEditPolicyError? {
        guard VisualContentHash.isValidSHA256(recipe.sourceContentHash) else {
            return .invalidSourceHash
        }
        guard !recipe.operations.isEmpty else { return .noOperations }
        guard recipe.operations.count <= maximumOperationCount else {
            return .tooManyOperations(maximum: maximumOperationCount)
        }

        var generativeIndex: Int?
        for (index, operation) in recipe.operations.enumerated() {
            if let error = validationError(for: operation) { return error }
            guard operation.requiresGenerativeModel else { continue }
            guard generativeIndex == nil else { return .multipleGenerativeOperations }
            generativeIndex = index
        }
        if let generativeIndex, generativeIndex != recipe.operations.indices.last {
            return .generativeOperationMustBeLast
        }
        return nil
    }

    private static func validationError(
        for operation: VisualEditOperation
    ) -> VisualEditPolicyError? {
        switch operation {
        case .trimUniformMargins(let tolerance):
            return (0...0.25).contains(tolerance) ? nil : .invalidTrimTolerance
        case .crop(let rect):
            let values = [rect.x, rect.y, rect.width, rect.height]
            guard values.allSatisfy(\.isFinite), rect.width > 0, rect.height > 0,
                  rect.x >= 0, rect.y >= 0,
                  rect.x + rect.width <= 1, rect.y + rect.height <= 1 else {
                return .invalidCrop
            }
            return nil
        case .resize(let maximum):
            return (minimumOutputPixelDimension...maximumOutputPixelDimension).contains(maximum)
                ? nil : .invalidResize
        case .tone(let brightness, let contrast, let saturation, let warmth):
            guard brightness.isFinite, contrast.isFinite,
                  saturation.isFinite, warmth.isFinite,
                  (-1...1).contains(brightness), (0.25...4).contains(contrast),
                  (0...2).contains(saturation), (-1...1).contains(warmth) else {
                return .invalidTone
            }
            return nil
        case .removeBackground:
            return nil
        case .generative(let prompt):
            let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return .emptyGenerativeInstruction }
            return cleaned.count <= maximumGenerativeInstructionCharacters
                ? nil
                : .generativeInstructionTooLong(maximum: maximumGenerativeInstructionCharacters)
        }
    }
}
