import Foundation

/// Recognizes only a standalone request to continue, never a substring of a new instruction.
public enum ContinuationInstruction {
    public static func matches(_ text: String) -> Bool {
        guard text.count <= 64 else { return false }
        let compact = text.lowercased().filter { !$0.isWhitespace }
        let pattern = #"^(?:ok|okay|うん|はい|じゃあ|じゃ|それじゃ|それじゃあ)*(?:続けて|続けよう|続けよ|進めて|進めよう|再開(?:して)?|お願い(?:します)?|よろしく(?:お願いします)?|tudukete|tsuzukete)(?:ちょ|ね|よ|〜|～|ー|!|！|。|\.)*$"#
        return compact.range(of: pattern, options: .regularExpression) != nil
    }
}
