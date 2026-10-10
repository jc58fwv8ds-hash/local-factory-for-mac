import Foundation

extension VerifierRelationGraphE {
    // MARK: member parsing (Phase 3 shapes + enum cases + return types)

    static func members(owner: String, isEnum: Bool, file: String, source: String, tokens: [Token], pairs: [Int: Int],
                                start: Int, end: Int, issues: inout [String], blocked: inout Set<String>) -> [Declaration] {
        var result: [Declaration] = [], i = start
        let lines = source.components(separatedBy: "\n")
        func simpleType(_ at: Int) -> String? { at < tokens.count && tokens[at].identifier ? tokens[at].text : nil }
        while i < end {
            let first = i
            var isStatic = false
            while i < end, VerifierRelationIndex.modifiers.contains(tokens[i].text) {
                if tokens[i].text == "static" { isStatic = true }
                if i + 1 < end, tokens[i + 1].text == "(", let close = pairs[i + 1] { i = close + 1 } else { i += 1 }
            }
            guard i < end else { break }
            let keyword = tokens[i].text
            if ["struct", "enum", "class", "protocol", "actor", "extension", "typealias", "subscript"].contains(keyword) {
                if i + 1 < end, tokens[i + 1].identifier { blocked.insert(tokens[i + 1].text) }
                var j = i
                while j < end, tokens[j].text != "{", !(keyword == "typealias" && j > i && tokens[j].line != tokens[i].line) { j += 1 }
                i = (j < end && tokens[j].text == "{") ? (pairs[j] ?? j) + 1 : j
                continue
            }
            guard ["func", "let", "var", "init", "case"].contains(keyword) else {
                if tokens[i].text == "{", let close = pairs[i] { i = close + 1 } else { i += 1 }
                continue
            }
            if keyword == "case" {
                let line = tokens[i].line
                var k = i + 1, names: [(String, [Token])] = []
                while k < end, tokens[k].line == line {
                    guard tokens[k].identifier else { issues.append("unsupportedCase:\(owner)"); break }
                    let name = tokens[k].text
                    k += 1
                    var raw: [Token] = []
                    if k < end, tokens[k].text == "(", let close = pairs[k] { k = close + 1 }
                    if k < end, tokens[k].text == "=" {
                        k += 1
                        while k < end, tokens[k].line == line, tokens[k].text != "," { raw.append(tokens[k]); k += 1 }
                    }
                    names.append((name, raw))
                    if k < end, tokens[k].text == ",", tokens[k].line == line { k += 1 } else { break }
                }
                let range = line...line
                let sharedBefore = first > start && tokens[first - 1].line == line
                if isEnum && !sharedBefore {
                    for (name, raw) in names {
                        let symbol = owner + "." + name
                        let node = P.Node(id: file + ":" + symbol + ":" + String(line), file: file, symbol: symbol, sourceRange: range,
                                          exactText: lines[range].joined(separator: "\n"), evidenceType: "enumCase")
                        result.append(.init(node: node, owner: owner, name: name, kind: "case", isStatic: true, isEnum: false, signature: [],
                                            tokens: raw, valueType: owner, returnType: nil, conformances: []))
                    }
                } else if !isEnum { issues.append("unsupportedCase:\(owner)") }
                while i < end, tokens[i].line == line { if let close = pairs[i], ["(", "["].contains(tokens[i].text) { i = close + 1 } else { i += 1 } }
                continue
            }
            let name = keyword == "init" ? "init" : (i + 1 < end && tokens[i + 1].identifier ? tokens[i + 1].text : "")
            guard !name.isEmpty else { issues.append("unsupportedMember:\(owner)"); i += 1; continue }
            var last = keyword == "init" ? i : i + 1
            var signature: [Token] = [], body: [Token] = [], valueType: String? = nil, returnType: String? = nil
            if keyword == "func" || keyword == "init" {
                var open = last + 1
                if open < end, tokens[open].text == "<" { issues.append("unsupportedGeneric:\(owner).\(name)"); blocked.insert(name) }
                if keyword == "init", open < end, tokens[open].text == "?" { open += 1 }
                guard open < end, tokens[open].text == "(", let parametersEnd = pairs[open] else {
                    issues.append("unsupportedSignature:\(owner).\(name)"); i = last + 1; continue
                }
                last = parametersEnd + 1
                while last < end && tokens[last].text != "{" && tokens[last].line <= tokens[parametersEnd].line + 1
                        && !VerifierRelationIndex.modifiers.contains(tokens[last].text) && !["func", "var", "let", "init"].contains(tokens[last].text) { last += 1 }
                guard last < end, tokens[last].text == "{", let close = pairs[last] else {
                    issues.append("missingBody:\(owner).\(name)"); i = max(last, i + 1); continue
                }
                signature = Array(tokens[open...(last - 1)])
                if let arrow = (parametersEnd..<last).first(where: { tokens[$0].text == "-" && $0 + 1 < last && tokens[$0 + 1].text == ">" }) {
                    returnType = simpleType(arrow + 2)
                }
                if keyword == "init" { returnType = owner }
                body = last + 1 <= close - 1 ? Array(tokens[(last + 1)...(close - 1)]) : []
                last = close
            } else {
                var j = last + 1
                if j < end, tokens[j].text == ":" {
                    valueType = simpleType(j + 1)
                    j += 1
                    while j < end, tokens[j].line == tokens[first].line, !["=", "{"].contains(tokens[j].text) {
                        if let close = pairs[j], ["(", "["].contains(tokens[j].text) { j = close + 1 } else { j += 1 }
                    }
                }
                if j < end, tokens[j].text == "=" {
                    var k = j + 1
                    var lastLine = tokens[j].line
                    while k < end, tokens[k].line <= lastLine {
                        if let close = pairs[k], ["(", "[", "{"].contains(tokens[k].text) { lastLine = max(lastLine, tokens[close].line); k = close + 1 } else { k += 1 }
                    }
                    body = Array(tokens[(j + 1)..<k]); last = k - 1
                    if valueType == nil, body.count >= 1, body[0].identifier, body[0].text.first?.isUppercase == true,
                       body.count == 1 || body[1].text == "(" { valueType = body[0].text }   // initializer-derived type
                } else if j < end, tokens[j].text == "{", let close = pairs[j] {
                    body = j + 1 <= close - 1 ? Array(tokens[(j + 1)...(close - 1)]) : []; last = close
                } else {
                    guard !isStatic || keyword == "var" else { issues.append("unsupportedConstant:\(owner).\(name)"); i = j; continue }
                    last = max(i + 1, j - 1)
                }
            }
            let range = tokens[first].line...tokens[last].line
            let sharedBefore = first > start && tokens[first - 1].line == range.lowerBound
            let sharedAfter = last + 1 < tokens.count && tokens[last + 1].line == range.upperBound && last + 1 != end
            if sharedBefore || sharedAfter || (first > 0 && tokens[first - 1].line == range.lowerBound && tokens[first - 1].text == "{") {
                issues.append("sharedDeclarationLine:\(owner).\(name)"); i = last + 1; continue
            }
            let symbol = owner + "." + name
            let node = P.Node(id: file + ":" + symbol + ":" + String(range.lowerBound), file: file, symbol: symbol, sourceRange: range,
                              exactText: lines[range].joined(separator: "\n"),
                              evidenceType: keyword == "func" || keyword == "init" ? "functionDeclaration" : "propertyDeclaration")
            result.append(.init(node: node, owner: owner, name: name, kind: keyword, isStatic: isStatic, isEnum: false,
                                signature: signature, tokens: body, valueType: valueType, returnType: returnType, conformances: []))
            i = last + 1
        }
        return result
    }
}
