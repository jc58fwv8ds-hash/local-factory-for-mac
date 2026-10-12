import Foundation

/// A calculator for the examiner's blind recheck (backlog #44, 2026-10-11). The one wrong alarm in 10 of the 27B
/// examiner (c2-03) was a slip in hand arithmetic, "49 × 1021 = 49929" (it is 50029), repeated on every retry, so the
/// steps of the working are checked here and a wrong one is sent back with the right result. On the 10 past alarms
/// (eval/offline/calc_judge.py) that alarm was withdrawn and the 9 right ones stayed.
enum ArithmeticCheck {
    /// "left = result" steps of plain numbers whose result is wrong, written as the right equation ("49 * 1021 = 50029").
    /// Division counts as right both exactly and as Swift's integer division ("51050 / 10000 = 5"). In a chain
    /// "(20 + 9) / 10 = 29 / 10 = 2" a result that goes on with an operator is the next left side, not a result.
    static func wrongSteps(in text: String) -> [String] {
        let plain = text.replacingOccurrences(of: "\\times", with: "*").replacingOccurrences(of: "\\cdot", with: "*")
            .replacingOccurrences(of: "\\div", with: "/").replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "$", with: "")
        let number = #"-?\d[\d_,]*(?:\.\d+)?"#
        // One line at a time ([ \t], not \s): a bullet "*" on the next line is not an operator.
        let pattern = #"((?:\(?[ \t]*NUM[ \t]*\)?[ \t]*[-+*/][ \t]*)+\(?[ \t]*NUM[ \t]*\)?)[ \t]*=[ \t]*(NUM)(?![\d_.,]*[ \t]*[-+*/(])"#
            .replacingOccurrences(of: "NUM", with: number)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var wrong: [String] = []
        for match in regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let left = Range(match.range(at: 1), in: plain), let right = Range(match.range(at: 2), in: plain) else { continue }
            let expression = plain[left].replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ",", with: "")
            guard let claimed = Double(plain[right].replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ",", with: "")),
                  let exact = evaluate(expression, integerDivision: false) else { continue }
            let whole = expression.contains(".") ? exact : evaluate(expression, integerDivision: true) ?? exact
            guard abs(exact - claimed) > 0.01, abs(whole - claimed) > 0.01 else { continue }
            let shown = expression.contains("/") && !expression.contains(".") ? whole : exact
            let text = shown == shown.rounded() && abs(shown) < 1e15 ? String(Int64(shown)) : String(format: "%g", shown)
            wrong.append(plain[left].trimmingCharacters(in: .whitespaces) + " = " + text)
        }
        return wrong
    }

    /// + - * / and parentheses, left to right with the usual precedence.
    static func evaluate(_ expression: String, integerDivision: Bool) -> Double? {
        var tokens: [String] = []
        var current = ""
        for character in expression where !character.isWhitespace {
            if character.isNumber || character == "." { current.append(character); continue }
            if character == "-", current.isEmpty, tokens.last.map({ "+-*/(".contains($0) }) ?? true { current.append(character); continue }
            if !current.isEmpty { tokens.append(current); current = "" }
            tokens.append(String(character))
        }
        if !current.isEmpty { tokens.append(current) }
        var index = 0
        func primary() -> Double? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]; index += 1
            if token == "(" {
                let value = sum()
                guard index < tokens.count, tokens[index] == ")" else { return nil }
                index += 1
                return value
            }
            return Double(token)
        }
        func product() -> Double? {
            guard var value = primary() else { return nil }
            while index < tokens.count, tokens[index] == "*" || tokens[index] == "/" {
                let op = tokens[index]; index += 1
                guard let rhs = primary() else { return nil }
                if op == "*" { value *= rhs } else {
                    guard rhs != 0 else { return nil }
                    value = integerDivision ? (value / rhs).rounded(.towardZero) : value / rhs
                }
            }
            return value
        }
        func sum() -> Double? {
            guard var value = product() else { return nil }
            while index < tokens.count, tokens[index] == "+" || tokens[index] == "-" {
                let op = tokens[index]; index += 1
                guard let rhs = product() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }
        let value = sum()
        return index == tokens.count ? value : nil
    }
}
