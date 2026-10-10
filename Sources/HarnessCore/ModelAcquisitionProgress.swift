import Foundation

public struct ModelAcquisitionProgress: Equatable, Sendable {
    public let fraction: Double?
    public let status: String

    public init(fraction: Double?, status: String) {
        self.fraction = fraction.map { min(max($0, 0), 1) }
        self.status = status
    }
}

public enum ModelAcquisitionProgressParser {
    public static func parse(_ output: String) -> ModelAcquisitionProgress? {
        let cleaned = stripControlSequences(output).lowercased()
        let fraction = lastPercentage(in: cleaned).map { $0 / 100 }

        if cleaned.contains("verifying sha256") || cleaned.contains("verifying checksum") {
            return ModelAcquisitionProgress(
                fraction: nil,
                status: "ダウンロード内容を検証しています"
            )
        }
        if cleaned.contains("writing manifest") || cleaned.contains("finalizing") {
            return ModelAcquisitionProgress(
                fraction: nil,
                status: "モデル情報を保存しています"
            )
        }
        if fraction != nil,
           cleaned.contains("pulling")
            || cleaned.contains("download")
            || cleaned.contains("fetch") {
            return ModelAcquisitionProgress(
                fraction: fraction,
                status: "現在のモデルデータをダウンロードしています"
            )
        }
        if cleaned.contains("pulling manifest") || cleaned.contains("resolving") {
            return ModelAcquisitionProgress(
                fraction: nil,
                status: "モデル情報を確認しています"
            )
        }
        return nil
    }

    private static func lastPercentage(in text: String) -> Double? {
        let pattern = #"(?<![0-9])([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.matches(in: text, range: range).last,
              let percentageRange = Range(match.range(at: 1), in: text),
              let percentage = Double(text[percentageRange]),
              percentage >= 0,
              percentage <= 100 else {
            return nil
        }
        return percentage
    }

    private static func stripControlSequences(_ text: String) -> String {
        let pattern = #"\u{001B}\[[0-?]*[ -/]*[@-~]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
    }
}
