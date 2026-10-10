import Foundation

/// Keeps partial speech separate from finalized text and prevents repeated volatile results.
public struct VoiceTranscriptAssembler: Equatable, Sendable {
    public private(set) var finalizedText = ""
    public private(set) var volatileText = ""

    public init() {}

    public mutating func receive(_ fragment: String, isFinal: Bool) -> String {
        let cleaned = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return combinedText }
        if isFinal {
            finalizedText = Self.join(finalizedText, cleaned)
            volatileText = ""
        } else {
            volatileText = cleaned
        }
        return combinedText
    }

    public var combinedText: String {
        Self.join(finalizedText, volatileText)
    }

    private static func join(_ leading: String, _ trailing: String) -> String {
        guard !leading.isEmpty else { return trailing }
        guard !trailing.isEmpty else { return leading }
        let needsSpace = leading.last?.isASCIIWord == true && trailing.first?.isASCIIWord == true
        return leading + (needsSpace ? " " : "") + trailing
    }
}

public enum VoiceDraftComposition {
    /// Voice text is additive. An existing typed draft is never silently replaced.
    public static func inserting(_ transcript: VoiceTranscript, into draft: String) -> String {
        let spoken = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return draft }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return spoken
        }
        if draft.last?.isWhitespace == true {
            return draft + spoken
        }
        return draft + "\n" + spoken
    }
}

private extension Character {
    var isASCIIWord: Bool {
        unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
        }
    }
}
