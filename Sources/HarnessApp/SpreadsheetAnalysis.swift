import Foundation

/// Analysis of attached spreadsheets (file operations stage 3, 2026-10-11): the model writes one SQL query; DuckDB
/// computes the numbers. Every sheet (and CSV) is loaded into an in-memory table first, then file access is switched off
/// and the configuration locked, so the model's SQL can read only those tables and cannot read or write any file.
/// The numbers on screen are DuckDB's, never the model's.
enum SpreadsheetAnalysis {
    struct Table: Equatable, Sendable {
        let name: String        // SQL name, e.g. t1
        let label: String       // 「売上.xlsx / シート「4月」」
        let columns: [String]
        let rows: [[String]]    // data rows (the first row is the header)
    }

    struct Result: Equatable, Sendable {
        let columns: [String]
        let rows: [[String]]
    }

    enum Failure: LocalizedError {
        case noDuckDB, query(String)
        var errorDescription: String? {
            switch self {
            case .noDuckDB: "集計に使う DuckDB が見つかりません(brew install duckdb で入ります)"
            case .query(let message): "集計の SQL を実行できませんでした: \(message)"
            }
        }
    }

    static let duckdbPaths = ["/opt/homebrew/bin/duckdb", "/usr/local/bin/duckdb"]

    /// Tables from .xlsx sheets and .csv files; the first row of each is the header.
    static func tables(from urls: [URL]) throws -> [Table] {
        var tables: [Table] = []
        for url in urls {
            let sheets: [(String, [[String]])]
            if url.pathExtension.lowercased() == "xlsx" {
                sheets = try XLSXReader.sheets(at: url).map { ("\(url.lastPathComponent) / シート「\($0.name)」", $0.rows) }
            } else {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .shiftJIS)) ?? ""
                sheets = [(url.lastPathComponent, text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map(csvFields))]
            }
            for (label, rows) in sheets where !rows.isEmpty {
                let width = rows.map(\.count).max() ?? 0
                var columns = (0..<width).map { index in
                    let raw = index < rows[0].count ? rows[0][index].trimmingCharacters(in: .whitespaces) : ""
                    return raw.isEmpty ? "列\(index + 1)" : raw
                }
                for index in columns.indices where columns[..<index].contains(columns[index]) { columns[index] += "_\(index + 1)" }
                tables.append(Table(name: "t\(tables.count + 1)", label: label, columns: columns,
                                    rows: rows.dropFirst().map { row in (0..<width).map { $0 < row.count ? row[$0] : "" } }))
            }
        }
        return tables
    }

    /// What the model sees: table names, columns and the first rows.
    static func schema(_ tables: [Table]) -> String {
        tables.map { table in
            "表 \(table.name)(\(table.label)、\(table.rows.count) 行): 列 " + table.columns.map { "\"\($0)\"" }.joined(separator: ", ")
                + "\n" + table.rows.prefix(5).map { $0.joined(separator: " | ") }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func prompt(instruction: String, tables: [Table], previousError: String? = nil) -> String {
        """
        ユーザーは表のデータについてこう聞いています:
        \(instruction)

        使える表(DuckDB。列名は日本語なので必ず "列名" のように二重引用符で囲む):
        \(schema(tables))
        \(previousError.map { "\n前回の SQL はこのエラーで失敗しました。直してください: \($0)\n" } ?? "")
        答えを出す SQL(SELECT 文 1 つ)だけを ```sql のブロックで返してください。数値の列が文字として入っている場合は TRY_CAST(… AS DOUBLE) を使う。結果は 200 行以内。
        """
    }

    static func sql(from response: String) -> String? {
        let text = response.components(separatedBy: "```").enumerated()
            .first { $0.offset % 2 == 1 }?.element ?? response
        let query = text.replacingOccurrences(of: #"^\s*sql\s*\n"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        return query.lowercased().hasPrefix("select") || query.lowercased().hasPrefix("with") ? query : nil
    }

    /// Loads the tables, locks file access, runs the query; returns the result as text cells.
    static func run(_ query: String, tables: [Table]) throws -> Result {
        guard let duckdb = duckdbPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw Failure.noDuckDB }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var script = ""
        for table in tables {
            let csv = folder.appendingPathComponent("\(table.name).csv")
            try ([table.columns] + table.rows).map { $0.map(csvQuote).joined(separator: ",") }.joined(separator: "\n")
                .write(to: csv, atomically: true, encoding: .utf8)
            script += "CREATE TABLE \(table.name) AS SELECT * FROM read_csv('\(csv.path)', header=true, all_varchar=false, sample_size=-1);\n"
        }
        script += "SET enable_external_access = false;\nSET lock_configuration = true;\n.mode json\n\(query);\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: duckdb)
        process.arguments = [":memory:"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, message.isEmpty || !message.contains("Error") else {
            throw Failure.query(String(message.prefix(400)))
        }
        let rows = (try? JSONSerialization.jsonObject(with: data.isEmpty ? Data("[]".utf8) : data)) as? [[String: Any]] ?? []
        let columns = rows.first.map { first in
            // JSON objects lose column order; recover it from the SELECT output's first object keys as DuckDB wrote them.
            orderedKeys(in: data) ?? Array(first.keys)
        } ?? []
        return Result(columns: columns, rows: rows.prefix(200).map { row in columns.map { text(row[$0]) } })
    }

    static func orderedKeys(in data: Data) -> [String]? {
        let text = String(decoding: data, as: UTF8.self)
        guard let open = text.range(of: "{"), let close = text[open.upperBound...].range(of: "}") else { return nil }
        let object = String(text[open.lowerBound..<close.upperBound])
        let keys = SecondKeys.matches(in: object)
        return keys.isEmpty ? nil : keys
    }

    static func text(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let number as NSNumber:
            let double = number.doubleValue
            return double == double.rounded() && abs(double) < 1e15 ? String(Int64(double)) : String(format: "%.4g", double)
        case let string as String: return string
        default: return "\(value!)"
        }
    }

    static func csvQuote(_ field: String) -> String {
        field.contains(",") || field.contains("\"") || field.contains("\n") ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
    }

    static func csvFields(_ line: String) -> [String] {
        var fields: [String] = [], current = "", quoted = false
        var iterator = Array(line).makeIterator(), pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if character == "\"" {
                if quoted, let next = iterator.next() {
                    if next == "\"" { current.append("\"") } else { quoted = false; pending = next }
                } else { quoted.toggle() }
            } else if character == ",", !quoted {
                fields.append(current); current = ""
            } else { current.append(character) }
        }
        fields.append(current)
        return fields
    }
}

/// Keys of one JSON object in the order they appear ("key": …), for keeping the SELECT's column order.
private enum SecondKeys {
    static func matches(in object: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"\s*:"#) else { return [] }
        return regex.matches(in: object, range: NSRange(object.startIndex..., in: object)).compactMap {
            Range($0.range(at: 1), in: object).map { String(object[$0]) }
        }
    }
}
