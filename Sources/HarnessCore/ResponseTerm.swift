import Foundation
import NaturalLanguage

public struct ResponseTerm: Equatable, Sendable {
    public let text: String
    public let context: String
    public let range: NSRange
}

/// An index into the displayed response, using UTF-16 offsets shared with AppKit.
public struct ResponseTermIndex: Sendable {
    public let terms: [ResponseTerm]

    public init(text: String) {
        let source = String(text.prefix(24_000))
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = source
        let excluded = Self.excludedRanges(in: source)
        var result: [ResponseTerm] = []
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
            let word = String(source[range])
            let nsRange = NSRange(range, in: source)
            guard (2...64).contains(word.count),
                  word.unicodeScalars.contains(where: CharacterSet.letters.contains),
                  !Self.commonWords.contains(word.lowercased()),
                  !excluded.contains(where: { NSIntersectionRange($0, nsRange).length > 0 })
            else { return true }
            let start = source.index(range.lowerBound, offsetBy: -180, limitedBy: source.startIndex)
                ?? source.startIndex
            let end = source.index(range.upperBound, offsetBy: 300, limitedBy: source.endIndex)
                ?? source.endIndex
            result.append(ResponseTerm(text: word, context: String(source[start..<end]), range: nsRange))
            return true
        }
        terms = result
    }

    public func term(atUTF16Offset offset: Int) -> ResponseTerm? {
        terms.first { NSLocationInRange(offset, $0.range) }
    }

    private static let commonWords: Set<String> = [
        "です", "ます", "ました", "ください", "する", "した", "して", "いる",
        "ある", "この", "その", "ここ", "こと", "もの", "ため", "よう", "から",
        "the", "and", "for", "with", "this", "that", "are", "you"
    ]

    private static func excludedRanges(in text: String) -> [NSRange] {
        // URLs, addresses and code fragments are not dictionary terms.
        let pattern = "(?s)```.*?(?:```|$)|`[^`\\n]*`|https?://[^\\s]+|[\\w.+-]+@[\\w.-]+"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }
}
