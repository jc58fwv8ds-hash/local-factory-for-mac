import Foundation

/// How to fix the build errors that come up again and again, said to the model with the error (2026-11-10: on
/// 「main actor-isolated property 'isListening' can not be mutated from a nonisolated context」 in an audio tap and a speech
/// result handler, the local model returned the file unchanged, and 「おまかせ」 stopped). One line per kind, at most.
public enum BuildErrorAdvice {
    static let rules: [(pattern: String, advice: String)] = [
        // Well-known traps seen from a failed test and its log (2026-11-10, PlamoTranslator).
        (#"\[記録: [^\]]*simulator[^\]]*(ggml_metal|mlx)|\[記録: [^\]]*(ggml_metal|mlx)[^\]]*simulator"#,
         "直し方: iPhone のシミュレータでは GPU(Metal)を使う機械学習の部品(llama.cpp / ggml / MLX)が正しく計算できず、"
            + "結果が空や崩れたものになります。#if targetEnvironment(simulator) のときは GPU を使わない設定"
            + "(llama.cpp なら n_gpu_layers = 0)にし、実機では今のまま GPU を使ってください。"),
        (#"(isEmpty|→ \"\")[^\[]*\[記録: [^\]]*llama"#,
         "直し方: 文章を作るモデルの結果が空のときは、指示文の先頭に文頭の記号(BOS)が要るのに付けていないことが多いです。"
            + "llama_tokenize の add_special を true にしているか、終わりの判定(EOG や区切りの記号)で最初の 1 語目から止めていないかを確かめてください。"),
        (#"from (a )?nonisolated deinit|in a nonisolated deinit"#,
         "直し方: deinit は main actor の外で動くので、@MainActor のクラスのプロパティには一切触れられません。deinit の中身は"
            + "すべて消して空にし(必要なら deinit ごと消す)、片づけは stop() など main actor のメソッドで行ってください。"),
        (#"main actor-isolated .* (can not|cannot) be (mutated|referenced|used)|call to main actor-isolated .* in a synchronous nonisolated context"#,
         "直し方: このクラスは @MainActor です。音声のタップ、認識結果のハンドラ、通知などのクロージャの中で値を変えたり"
            + "メソッドを呼んだりするときは、Task { @MainActor [weak self] in self?.… } で包んでください。クロージャの外の"
            + "メインスレッドのコードはそのままにします。エラーの行が deinit の中なら、deinit は main actor の外で動くので、"
            + "そこでの @Published などへの代入は消してください(片づけに要る処理は stop() など main actor のメソッドへ移します)。"),
        (#"(risks causing data races|non-Sendable type|capture of .* with non-sendable type)"#,
         "直し方: クロージャへ渡す値を、送る前にローカルの let に取り出してから使うか、型に Sendable を付けられるか確かめてください。"),
        (#"cannot (assign|convert) value of type '(Unsafe(Mutable)?Pointer<\w+>|OpaquePointer)\??' to (type|specified type) '(Unsafe(Mutable)?Pointer<\w+>|OpaquePointer)"#,
         "直し方: C の関数が返すポインタの型(UnsafeMutablePointer<…> か OpaquePointer)をヘッダーの宣言どおりに使い、"
            + "それを入れるプロパティの型もその型に合わせてください。別のポインタ型へ変換しないでください。"),
        (#"cannot convert value of type '(Int32|Int|Bool)' to expected argument type '(Bool|Int32|Int)'"#,
         "直し方: 引数の型を宣言に合わせてください(C の bool は Swift の Bool、int32_t は Int32)。"),
        (#"cannot convert value of type '\[[^\]]+\]' to expected argument type 'Unsafe(Mutable)?Pointer<"#,
         "直し方: Swift の配列を C の関数のポインタ引数に渡すときは、var の配列に & を付けて渡すか(&tokens)、"
            + "tokens.withUnsafeMutableBufferPointer { $0.baseAddress } の中で呼んでください。"),
        (#"call can throw,? but (it )?is not marked with 'try'|errors thrown from here are not handled"#,
         "直し方: その呼び出しの前に try を付け、呼んでいる関数に throws を付けるか、do { try … } catch { … } で受けて"
            + "エラーを状態の文言などに出してください。try? で黙って捨てないでください。"),
        (#"'async' call in a function that does not support concurrency"#,
         "直し方: async の関数は、async の関数の中で await を付けて呼ぶか、同期の関数からなら Task { await … } で包んで呼んでください。"),
        (#"inheritance from a final class|overriding non-open (instance )?method outside of its defining module|instance method overrides a 'final' instance method"#,
         "直し方: final class は継承できません。テストで偽物を作るために継承しないでください。テストでは本物の型をそのまま作り、"
            + "マイク・スピーカー・通信・大きなモデルを動かさずに確かめられること(初期の状態、計算、文字の扱いなど)だけを確かめてください。"
            + "偽物のクラスはすべて消してください。"),
        (#"value of optional type .* must be unwrapped"#,
         "直し方: Optional の値は ?. か if let / guard let で取り出してください。! で強制的に取り出さないでください。"),
        (#"cannot find '\w+' in scope"#,
         "直し方: 名前の綴り、import の抜け、別ファイルにある型の名前を確かめてください。存在しない名前を作らないでください。"),
        (#"has no member '\w+'"#,
         "直し方: その型に本当にある名前だけを使ってください。推測で名前を変えないでください。"),
        (#"(missing argument|extra argument|incorrect argument label)"#,
         "直し方: 呼び出す関数の引数の名前と数を、定義に合わせてください。"),
    ]

    /// The advice for these error messages, each kind once.
    public static func lines(for messages: [String]) -> [String] {
        var found: [String] = []
        for (pattern, advice) in rules where !found.contains(advice) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if messages.contains(where: { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) {
                found.append(advice)
            }
        }
        return found
    }
}
