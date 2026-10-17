import Foundation

/// Computer Use stage 1 (2026-10-18, review item 2): instead of one fixed plan of four kinds of step, the model looks at
/// the app's accessibility elements, picks ONE next action, the app performs it and looks again, until the goal is done
/// or a limit is reached. Every action passes `ComputerUseRisk` first: an action that cannot be undone (send, buy,
/// delete, publish, sign in, agree…) waits for the user's approval each time, and typing into a password field is never
/// done by the agent (the user types it). The model only sees element labels and values, never secure-field contents.
public struct ComputerUseElement: Codable, Equatable, Sendable {
    public let id: Int
    public let role: String
    public let label: String
    public let value: String
    public let enabled: Bool

    public init(id: Int, role: String, label: String, value: String = "", enabled: Bool = true) {
        self.id = id; self.role = role; self.label = label; self.value = value; self.enabled = enabled
    }

    public var isSecureField: Bool { role == "AXSecureTextField" }
}

public struct ComputerUseObservation: Codable, Equatable, Sendable {
    public let application: String
    public let window: String
    public let elements: [ComputerUseElement]
    /// A PNG of the front window when the element list is too thin to act on (stage 3, 2026-10-18): the model then points
    /// at places on the picture instead.
    public let screenshot: Data?

    public init(application: String, window: String, elements: [ComputerUseElement], screenshot: Data? = nil) {
        self.application = application; self.window = window; self.elements = elements; self.screenshot = screenshot
    }

    /// What the model reads: one line per element, secure fields without their value.
    public var text: String {
        "アプリ: \(application)\nウィンドウ: \(window)\n" + elements.map { element in
            let value = element.isSecureField || element.value.isEmpty ? "" : " 値=「\(element.value.prefix(80))」"
            return "[\(element.id)] \(element.role) 「\(element.label)」\(value)\(element.enabled ? "" : " (無効)")"
        }.joined(separator: "\n")
    }
}

public enum ComputerUseAction: Codable, Equatable, Sendable {
    case openApplication(String)
    case press(Int)
    case type(Int, String)
    case menu([String])
    case key(String)
    /// A click at a place on the window's picture (fractions of its width and height) and what the model says is there.
    case click(Double, Double, String)
    /// Typing at the keyboard focus (adds, does not replace).
    case write(String)
    case done(String)
    case askUser(String)

    /// The line shown on the card and in the log.
    public func description(in observation: ComputerUseObservation?) -> String {
        func name(_ id: Int) -> String { observation?.elements.first { $0.id == id }.map { "「\($0.label)」" } ?? "[\(id)]" }
        switch self {
        case .openApplication(let app): return "「\(app)」を開く"
        case .press(let id): return "\(name(id)) を押す"
        case .type(let id, let text): return "\(name(id)) に「\(text.prefix(60))」と入力する"
        case .menu(let path): return "メニュー「\(path.joined(separator: " > "))」を選ぶ"
        case .key(let key): return "キー \(key) を押す"
        case .click(let x, let y, let target): return "画面の「\(target)」(\(Int(x * 100))%, \(Int(y * 100))%)を押す"
        case .write(let text): return "いまの入力位置に「\(text.prefix(60))」と書く"
        case .done(let summary): return "完了: \(summary)"
        case .askUser(let question): return "確認: \(question)"
        }
    }
}

public enum ComputerUseRisk: Equatable, Sendable {
    case safe
    case needsApproval(String)
    case forbidden(String)

    /// Words of actions that cannot be taken back. Matching is on the element's label or the menu item.
    static let irreversibleWords = [
        "送信", "送る", "購入", "買う", "注文", "支払", "決済", "削除", "消去", "ゴミ箱", "公開", "投稿", "共有", "確定",
        "同意", "承認", "許可", "ログイン", "サインイン", "登録", "解約", "退会", "上書き", "インストール", "アンインストール",
        "send", "buy", "purchase", "order", "pay", "checkout", "delete", "remove", "erase", "trash", "publish", "post",
        "share", "submit", "confirm", "agree", "accept", "allow", "sign in", "log in", "login", "register", "subscribe",
        "unsubscribe", "replace", "install", "uninstall", "empty"
    ]
    /// Key combinations that act without a confirmation step of their own.
    static let riskyKeys = ["cmd+delete", "cmd+backspace", "cmd+shift+delete", "cmd+q", "cmd+w", "return", "enter"]
    static let allowedKeys = Set(["return", "enter", "tab", "escape", "space", "up", "down", "left", "right",
                                  "cmd+a", "cmd+c", "cmd+v", "cmd+f", "cmd+n", "cmd+t", "cmd+l", "cmd+r", "cmd+s",
                                  "cmd+z", "cmd+w", "cmd+q", "cmd+delete", "cmd+backspace", "cmd+shift+delete"])

    public static func assess(_ action: ComputerUseAction, in observation: ComputerUseObservation?) -> ComputerUseRisk {
        func element(_ id: Int) -> ComputerUseElement? { observation?.elements.first { $0.id == id } }
        func irreversible(_ text: String) -> String? {
            irreversibleWords.first { text.localizedCaseInsensitiveContains($0) }
        }
        switch action {
        case .done, .askUser, .openApplication:
            return .safe
        case .press(let id):
            guard let target = element(id) else { return .forbidden("画面にない部品(\(id))は押しません") }
            if let word = irreversible(target.label) { return .needsApproval("「\(target.label)」は取り消せない操作(\(word))の可能性があります") }
            return .safe
        case .type(let id, _):
            guard let target = element(id) else { return .forbidden("画面にない部品(\(id))には入力しません") }
            if target.isSecureField || irreversible(target.label) == "ログイン" || target.label.localizedCaseInsensitiveContains("パスワード")
                || target.label.localizedCaseInsensitiveContains("password") {
                return .forbidden("パスワードなどの認証情報は入力しません。ご自身で入力してから「続ける」を押してください")
            }
            // Typing replaces the whole field. A field that already holds text (an open note, a draft, a document) loses it,
            // which cannot be undone reliably: on 2026-10-18 a test replaced an existing note's body this way. Ask first.
            // An empty body of a brand-new document ("名称未設定" / "Untitled") has nothing to lose; any other body may report
            // an empty value while it holds text, so it still asks.
            let newDocument = ["名称未設定", "Untitled"].contains { observation?.window.contains($0) == true }
            let filled = !target.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if filled || (target.role == "AXTextArea" && !newDocument) {
                return .needsApproval("「\(target.label.isEmpty ? target.role : target.label)」の今の中身を置き換えます(元の文章は消えます)")
            }
            return .safe
        case .menu(let path):
            if let word = path.compactMap(irreversible).first { return .needsApproval("メニュー「\(path.joined(separator: " > "))」は取り消せない操作(\(word))の可能性があります") }
            return .safe
        case .click(let x, let y, let target):
            guard observation?.screenshot != nil, (0...1).contains(x), (0...1).contains(y) else {
                return .forbidden("画面の画像の外は押しません")
            }
            if let word = irreversible(target) { return .needsApproval("「\(target)」は取り消せない操作(\(word))の可能性があります") }
            return .safe
        case .write:
            // Where the focus is cannot be checked on a picture; only a brand-new document is sure to hold nothing to lose.
            let newDocument = ["名称未設定", "Untitled"].contains { observation?.window.contains($0) == true }
            return newDocument ? .safe : .needsApproval("いま選ばれている場所に文字を書き足します(どこかは画像からの判断です)")
        case .key(let key):
            let normalized = key.lowercased().replacingOccurrences(of: " ", with: "")
            guard allowedKeys.contains(normalized) else { return .forbidden("キー \(key) は使いません") }
            return riskyKeys.contains(normalized) ? .needsApproval("キー \(key) は送信・削除・終了につながることがあります") : .safe
        }
    }
}

public enum ComputerUseAgentPrompt {
    public static func messages(goal: String, observation: ComputerUseObservation, history: [String]) -> [InferenceMessage] {
        let system = """
        あなたは Mac のアプリを、画面の部品の一覧を見ながら一手ずつ操作する係です。ユーザーの目的に向けて、次の一手だけを JSON 一つで返してください。
        使える一手:
        {"action": "open", "app": "アプリ名"}            アプリを開く(前面にする)
        {"action": "press", "id": 番号}                    部品を押す
        {"action": "type", "id": 番号, "text": "文字"}      入力欄に文字を入れる(前の内容は置き換わる)
        {"action": "menu", "path": ["ファイル", "新規"]}     メニューを選ぶ
        {"action": "key", "key": "return"}                 キー(return, tab, escape, cmd+f など)
        {"action": "done", "summary": "何をしたか"}          目的を果たした、またはこれ以上できない
        {"action": "ask", "question": "ユーザーへの質問"}    ユーザーにしか決められないこと・ログインが必要なとき
        決まり: パスワードや認証コードは入力しない(ask でユーザーに頼む)。送信・購入・削除・公開などはアプリ側でユーザーの確認が入るので、
        必要なら選んでよい。同じ一手を繰り返して変化がないときは別の方法か done。番号は下の一覧のものだけを使う。
        JSON の前に "reason": "一言" を入れてよい。JSON だけを返す。
        """ + (observation.screenshot == nil ? "" : """

        部品の一覧が少ないので、ウィンドウの画像も添えます。画像の上の場所を押すときは:
        {"action": "click", "x": 0.42, "y": 0.18, "target": "押すものの名前"}   (x, y は画像の幅と高さに対する割合)
        {"action": "write", "text": "文字"}                                     (いま選ばれている場所に書き足す)
        """)
        let user = """
        目的: \(goal)
        これまでの操作:
        \(history.isEmpty ? "(まだなし)" : history.suffix(12).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        いまの画面:
        \(observation.text)
        """
        return [InferenceMessage(role: .system, content: system), InferenceMessage(role: .user, content: user)]
    }

    public static func parse(_ response: String) -> ComputerUseAction? {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(response[start...end].utf8)) as? [String: Any],
              let action = object["action"] as? String else { return nil }
        func id() -> Int? { (object["id"] as? Int) ?? (object["id"] as? String).flatMap(Int.init) }
        func text(_ key: String) -> String? {
            (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { String($0.prefix(400)) }
        }
        switch action {
        case "open": return text("app").map { .openApplication($0) }
        case "press": return id().map { .press($0) }
        case "type": return id().flatMap { id in (object["text"] as? String).map { .type(id, String($0.prefix(400))) } }
        case "menu": return (object["path"] as? [String]).flatMap { $0.isEmpty ? nil : .menu(Array($0.prefix(5))) }
        case "key": return text("key").map { .key($0) }
        case "click":
            func number(_ key: String) -> Double? { (object[key] as? Double) ?? (object[key] as? Int).map(Double.init) }
            guard let x = number("x"), let y = number("y") else { return nil }
            return .click(x, y, text("target") ?? "")
        case "write": return (object["text"] as? String).map { .write(String($0.prefix(400))) }
        case "done": return .done(text("summary") ?? "完了しました")
        case "ask": return text("question").map { .askUser($0) }
        default: return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What the agent loop needs from the Mac (the app implements it with the accessibility API; tests with a fake).
public protocol ComputerUseControlling: Sendable {
    func observe() async throws -> ComputerUseObservation
    /// Performs one action; returns a short note of what happened.
    func perform(_ action: ComputerUseAction, in observation: ComputerUseObservation) async throws -> String
}

public enum ComputerUseOutcome: Equatable, Sendable {
    case done(String)
    case needsUser(String)
    case stopped(String)
    case stepLimit
}

public struct ComputerUseStep: Equatable, Sendable {
    public let action: String
    public let result: String
}

/// The loop: observe → ask the model → assess → (approval) → perform → record, at most `maximumSteps` times.
public enum ComputerUseAgent {
    public static let maximumSteps = 15

    public static func run(
        goal: String,
        controller: any ComputerUseControlling,
        decide: @Sendable ([InferenceMessage], Data?) async throws -> String,
        approve: @Sendable (String, String) async -> Bool,
        onStep: @Sendable (ComputerUseStep) async -> Void = { _ in },
        maximumSteps: Int = maximumSteps
    ) async -> ComputerUseOutcome {
        var history: [String] = []
        var unreadable = 0
        for _ in 0..<maximumSteps {
            if Task.isCancelled { return .stopped("止めました") }
            let observation: ComputerUseObservation
            do { observation = try await controller.observe() } catch {
                return .stopped("画面を読み取れませんでした: \(error.localizedDescription)")
            }
            let response: String
            do {
                response = try await decide(ComputerUseAgentPrompt.messages(goal: goal, observation: observation, history: history),
                                            observation.screenshot)
            } catch {
                return .stopped("次の一手を考えられませんでした: \(error.localizedDescription)")
            }
            guard let action = ComputerUseAgentPrompt.parse(response) else {
                unreadable += 1
                history.append("(読み取れない返事だったので、もう一度考える)")
                if unreadable >= 2 { return .stopped("次の一手を読み取れませんでした") }
                continue
            }
            let line = action.description(in: observation)
            // The same action three times in a row means the screen is not answering it (2026-10-18: a picture-only window
            // was clicked nine times at the same place); stop instead of spending the remaining steps.
            if history.suffix(2).count == 2, history.suffix(2).allSatisfy({ $0.hasPrefix(line + " → ") }) {
                await onStep(.init(action: line, result: "同じ一手が 3 回目なので行わない"))
                return .needsUser("「\(line)」を 2 回しても画面が変わらないので止めました。うまくいったか画面で確かめてください")
            }
            switch action {
            case .done(let summary):
                await onStep(.init(action: line, result: "完了"))
                return .done(summary)
            case .askUser(let question):
                await onStep(.init(action: line, result: "ユーザーの判断待ち"))
                return .needsUser(question)
            default: break
            }
            switch ComputerUseRisk.assess(action, in: observation) {
            case .forbidden(let reason):
                await onStep(.init(action: line, result: "行わない: \(reason)"))
                return .needsUser(reason)
            case .needsApproval(let reason):
                guard await approve(line, reason) else {
                    await onStep(.init(action: line, result: "ユーザーが止めた"))
                    return .stopped("「\(line)」はユーザーの判断で行いませんでした")
                }
            case .safe: break
            }
            let result: String
            do { result = try await controller.perform(action, in: observation) } catch {
                result = "失敗: \(error.localizedDescription)"
            }
            history.append("\(line) → \(result)")
            await onStep(.init(action: line, result: result))
        }
        return .stepLimit
    }
}
