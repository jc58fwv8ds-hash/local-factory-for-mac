import Foundation
import HarnessCore

/// Paired causal premises: a fluent repetition of the same design must not pass both cases.
enum ExplanationEvaluationScenarios {
    static let all: [ConversationEvaluationScenario] = [
        scenario(
            id: "why-relay-with-given-reason",
            conversation: [
                user("Watchで録音して、iPhoneは中継だけ、AIの処理はMacだけにしたいな。Macを閉じている間はiPhoneに録音を一時的に預けて、Macに届いたと確認した分だけiPhoneから消す案にしてね。具体的な通信方法はまだ調べていないから、動くかは未確認。まだファイルは変えないでね。"),
                assistant("Watchの録音をiPhoneが中継し、MacのAIで整理する案です。"),
                user("WatchからMacまでの流れと、iPhoneが間に入る理由を、難しい言葉を使わず3文で教えてちょ。")
            ],
            criteria: [
                "設計案としてWatch→iPhone→Macを説明する",
                "中継役だからの言い換えで済まさず、Macを閉じている間の一時預かりという理由を述べる",
                "Macの受取確認後だけiPhoneから削除する条件を保ち、通信が実装済み・検証済みとしない",
                "3文で平易に説明し、Appleの未確認の制限や保証を捏造しない"
            ]
        ),
        scenario(
            id: "why-relay-retracted",
            conversation: [
                user("Watchの録音をiPhoneに一時的に預けてからMacへ送る案にしたいな。まだ変更しないでね。"),
                assistant("iPhoneが中継する案ですね。"),
                user("やっぱりiPhoneは使わず、Macが受け取るまでWatchに録音を残す案に変えて。Macの受取確認が来た分だけWatchから消す形。通信方法はまだ調べていないから、実際に動くかは未確認だよ。"),
                user("なんでWatchに一度残すの？ 前の案との違いと理由を、3文で教えてちょ。")
            ],
            criteria: [
                "後の訂正を優先し、iPhoneを中継・保存先として再導入しない",
                "Macがまだ受け取れない間の録音を残すためと説明し、役割の言い換えで済まさない",
                "受取確認した分だけ消す条件と未検証の設計案という区別を保つ",
                "3文で自然に答え、実装済み・通信可能と断定しない"
            ]
        ),
        scenario(
            id: "why-without-evidence",
            conversation: [
                user("Macだけで使うメモを考えてる。まだファイルは変えないでね。"),
                assistant("一覧の読み込みを別にすれば、待ち時間が半分になります。"),
                user("なんで半分になるの？ まだ測ってないよね。難しい言葉なしで、2文で教えてちょ。")
            ],
            criteria: [
                "半分という効果の根拠がないと明示して前の断定を訂正する",
                "原因・数値を捏造せず、同じ条件で変更前後を測る確認方法を示す",
                "2文で答え、測定や変更を実行したと主張しない"
            ]
        ),
        ConversationEvaluationScenarios.all[1]
    ]

    private static func scenario(
        id: String, conversation: [ConversationMessage], criteria: [String]
    ) -> ConversationEvaluationScenario {
        let project = HarnessProject(
            name: "理由説明の合成検査", summary: "ローカルアプリの設計を相談中。実装・通信試験は未実施。",
            targets: [.macOS, .iPhone], stage: .design, progress: 0,
            currentActivity: "設計案を相談", workItems: [], activity: [], conversation: conversation
        )
        return ConversationEvaluationScenario(id: id, project: project, source: nil, reviewCriteria: criteria)
    }

    private static func user(_ text: String) -> ConversationMessage {
        ConversationMessage(role: .user, content: text)
    }

    private static func assistant(_ text: String) -> ConversationMessage {
        ConversationMessage(role: .assistant, content: text)
    }
}
