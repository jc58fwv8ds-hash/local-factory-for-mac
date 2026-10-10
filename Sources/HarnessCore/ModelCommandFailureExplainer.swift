import Foundation

public enum ModelCommandFailureExplainer {
    public static func installationMessage(
        from output: String,
        runtime: RuntimeKind
    ) -> String {
        let value = normalized(output)
        if value.contains("does not exist")
            || value.contains("failed to resolve artifact")
            || value.contains("not found") {
            return "モデル配布元を確認できませんでした。カタログを更新して、もう一度お試しください。"
        }
        if value.contains("permission")
            || value.contains("unauthorized")
            || value.contains("forbidden") {
            return "モデル配布元へのアクセスが許可されませんでした。公開状態またはランタイムのログイン状態を確認してください。"
        }
        if value.contains("network")
            || value.contains("connection")
            || value.contains("timed out")
            || value.contains("resolve host") {
            return "モデル配布元へ接続できませんでした。ネットワークを確認して再開してください。"
        }
        return "\(runtime.rawValue)でモデルを取得できませんでした。ランタイムの状態を確認して再開してください。"
    }

    public static func runtimeMessage(
        from output: String,
        runtime: RuntimeKind
    ) -> String {
        let value = normalized(output)
        if value.contains("connection") || value.contains("not running") {
            return "\(runtime.rawValue)を起動してください"
        }
        return "\(runtime.rawValue)のモデル一覧を取得できません"
    }

    private static func normalized(_ output: String) -> String {
        let ansiPattern = #"\u{001B}\[[0-?]*[ -/]*[@-~]"#
        let withoutANSI: String
        if let expression = try? NSRegularExpression(pattern: ansiPattern) {
            let range = NSRange(output.startIndex..., in: output)
            withoutANSI = expression.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: ""
            )
        } else {
            withoutANSI = output
        }
        return withoutANSI.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
            .map(String.init)
            .joined()
            .lowercased()
    }
}
