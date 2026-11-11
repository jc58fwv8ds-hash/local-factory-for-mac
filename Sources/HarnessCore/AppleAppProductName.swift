import Foundation

/// The Xcode product name made from the name the user gave the project (2026-11-10: creating 「14Translate」 from the
/// new-project sheet left the field at 「HarnessRemote」, and a name starting with a digit is refused). Words are joined
/// in CamelCase, symbols dropped, and a leading number is spelled out, so 「14Translate」 becomes 「FourteenTranslate」.
public enum AppleAppProductName {
    public static func suggested(from projectName: String) -> String {
        var name = projectName.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
            .filter { $0.isASCII }
        let digits = String(name.prefix(while: \.isNumber))
        if !digits.isEmpty {
            name = (spelled(digits) ?? "App" + digits) + name.dropFirst(digits.count)
        }
        if name.count < 3 { name = "My" + (name.isEmpty ? "App" : name) }
        return String(name.prefix(40))
    }

    static func spelled(_ digits: String) -> String? {
        guard let value = Int(digits), value < 1_000 else { return nil }
        let ones = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve",
                    "Thirteen", "Fourteen", "Fifteen", "Sixteen", "Seventeen", "Eighteen", "Nineteen"]
        let tens = ["", "", "Twenty", "Thirty", "Forty", "Fifty", "Sixty", "Seventy", "Eighty", "Ninety"]
        func below100(_ n: Int) -> String { n < 20 ? ones[n] : tens[n / 10] + (n % 10 == 0 ? "" : ones[n % 10]) }
        if value < 100 { return below100(value) }
        return ones[value / 100] + "Hundred" + (value % 100 == 0 ? "" : below100(value % 100))
    }
}
