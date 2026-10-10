import Foundation

public struct ExternalReviewPacket: Equatable, Sendable {
    public let content: String
    public let includedSourceFileCount: Int
    public let wasTruncated: Bool
    public let redactedLineCount: Int

    public init(
        content: String,
        includedSourceFileCount: Int,
        wasTruncated: Bool,
        redactedLineCount: Int
    ) {
        self.content = content
        self.includedSourceFileCount = includedSourceFileCount
        self.wasTruncated = wasTruncated
        self.redactedLineCount = redactedLineCount
    }
}

public enum ExternalReviewPacketBuilder {
    public static let maximumCharacters = 32_000
    private static let maximumValidationCharacters = 8_000

    public static func make(
        project: HarnessProject,
        rootPath: String,
        report: ProjectValidationReport,
        analysis: BuildFailureAnalysis?,
        sourceContext: SourceContextSnapshot?
    ) -> ExternalReviewPacket {
        let guidance = ValidationRevisionGuidanceBuilder.make(
            report: report,
            analysis: analysis
        )
        let source = formattedSource(sourceContext)
        let validation = formattedValidation(report, rootPath: rootPath)
        let diagnostics = formattedDiagnostics(analysis)
        let draft = """
        あなたはソフトウェア成果物のレビュー担当です。中程度の検討深度で、実装を断定せず修正案を考えてください。

        次の形式で日本語で回答してください。
        ## 現状
        検査結果と成果物から確認できる状態。
        ## 修正案
        優先順位を付けた具体的な変更。各項目に対象と理由を含める。
        ## 得られる結果
        修正によって利用者または保守性に生じる具体的な改善。
        ## リスクと再テスト
        壊れ得る箇所と、修正後に実行すべきテスト。

        制約:
        - 削除、公開、署名、外部送信を勝手に勧めない。
        - 資料にない実行結果やファイル変更を完了したと主張しない。
        - 修正範囲は小さくし、既存動作と責務境界を保つ。

        プロジェクト:
        - 名前: \(project.name)
        - 概要: \(project.summary)
        - 段階: \(project.stage.rawValue)
        - Harness一次診断: \(guidance.currentState)

        成果物（機密らしき行はHarnessが除外、容量上限あり）:
        \(source.text)

        検査・テスト結果:
        \(validation.text)

        抽出済み診断:
        \(diagnostics)
        """
        let redacted = redact(draft, rootPath: rootPath)
        let truncated = redacted.text.count > maximumCharacters
        let content = truncated
            ? String(redacted.text.prefix(maximumCharacters - 90))
                + "\n\n[Local Factory: レビュー包の容量上限に達したため、以降を省略しました]"
            : redacted.text

        return ExternalReviewPacket(
            content: content,
            includedSourceFileCount: sourceContext?.files.count ?? 0,
            wasTruncated: truncated
                || source.wasTruncated
                || validation.wasTruncated,
            redactedLineCount: redacted.redactedLineCount
        )
    }

    private static func formattedSource(
        _ snapshot: SourceContextSnapshot?
    ) -> (text: String, wasTruncated: Bool) {
        guard let snapshot, !snapshot.files.isEmpty else {
            return ("接続ソースは含まれていません。", false)
        }
        let body = snapshot.files.map { file in
            """
            --- \(file.relativePath)\(file.wasTruncated ? "（一部）" : "") ---
            \(file.content)
            """
        }.joined(separator: "\n")
        return (body, snapshot.wasTruncated)
    }

    private static func formattedValidation(
        _ report: ProjectValidationReport,
        rootPath: String
    ) -> (text: String, wasTruncated: Bool) {
        var remaining = maximumValidationCharacters
        var wasTruncated = false
        var sections: [String] = []
        for check in report.checks {
            let header = "--- \(check.kind.displayName): \(check.succeeded ? "成功" : "失敗") / 終了コード \(check.exitCode) ---\n"
            let normalized = check.output.replacingOccurrences(
                of: rootPath,
                with: "<project-root>"
            )
            let allowance = max(0, remaining - header.count)
            let output = String(normalized.suffix(allowance))
            wasTruncated = wasTruncated
                || check.outputWasTruncated
                || output.count < normalized.count
            sections.append(header + (output.isEmpty ? "出力なし" : output))
            remaining -= min(remaining, header.count + output.count)
            if remaining == 0 { break }
        }
        return (sections.joined(separator: "\n"), wasTruncated)
    }

    private static func formattedDiagnostics(_ analysis: BuildFailureAnalysis?) -> String {
        guard let analysis, !analysis.diagnostics.isEmpty else {
            return "安全に抽出できたエラー診断はありません。"
        }
        return analysis.diagnostics.map { diagnostic in
            let location = diagnostic.line.map { ":\($0)" } ?? ""
            return "- \(diagnostic.relativePath)\(location): \(diagnostic.message)"
        }.joined(separator: "\n")
    }

    private static func redact(
        _ text: String,
        rootPath: String
    ) -> (text: String, redactedLineCount: Int) {
        let normalized = text.replacingOccurrences(of: rootPath, with: "<project-root>")
        var count = 0
        let lines = normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map { line -> String in
            let value = String(line)
            if looksLikeCredential(value) {
                count += 1
                return "[Local Factory: 資格情報らしき行を除外しました]"
            }
            return maskKnownTokenShapes(value)
        }
        return (lines.joined(separator: "\n"), count)
    }

    private static func looksLikeCredential(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let labels = [
            "api_key", "apikey", "access_token", "auth_token", "password",
            "client_secret", "private_key", "authorization: bearer"
        ]
        let containsLabel = labels.contains(where: lowered.contains)
        let containsAssignment = line.contains("=") || line.contains(":")
        return containsLabel && containsAssignment
    }

    private static func maskKnownTokenShapes(_ line: String) -> String {
        let patterns = [
            #"sk-[A-Za-z0-9_-]{12,}"#,
            #"gh[pousr]_[A-Za-z0-9]{12,}"#,
            #"Bearer[ ]+[A-Za-z0-9._~+/=-]{12,}"#
        ]
        return patterns.reduce(line) { partial, pattern in
            partial.replacingOccurrences(
                of: pattern,
                with: "<redacted-token>",
                options: .regularExpression
            )
        }
    }
}
