import HarnessCore
import SwiftUI

/// 「止める内容の設定」 in the model settings and the app's 設定… window (2026-11-02): the two fixed lines, the words they
/// catch (2026-11-04: every word but a small core is the user's to remove, restore or add), the phrases registered after a
/// false detection, and retrying a refusal with the refusal model.
struct ContentGuardSection: View {
    @State private var phrases = ContentGuardSettings().exceptions
    @State private var sexual = ContentGuardSettings().words(.sexual)
    @State private var minor = ContentGuardSettings().words(.minor)
    @State private var retry = ContentGuardSettings().retryRefusals
    @State private var draft = ""
    @State private var sexualDraft = ""
    @State private var minorDraft = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("止める内容の設定", systemImage: "hand.raised").font(.harness(.headline))
            Text("止めるのは次の 2 つだけで、この 2 つの決まり自体は外せません: 未成年を性的に描く内容(性的な言葉と未成年を示す言葉が同じ指示にあるとき)と、実在する人の写真を性的に作り替えること(本人の同意を確認します)。")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            Toggle("モデルが断ったとき、断りの少ないモデルでやり直す", isOn: Binding(get: { retry }, set: { retry = $0; ContentGuardSettings().retryRefusals = $0 }))
            Text("下の言葉は、未成年の線にだけ使います。性的な言葉だけ、未成年の言葉だけでは何も止めません(大人を描く研究やデッサンは止まりません)。")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            wordList("未成年を示す言葉", list: .minor, words: $minor, draft: $minorDraft)
            wordList("性的な言葉", list: .sexual, words: $sexual, draft: $sexualDraft)
            Divider()
            Text("誤って止められた言い回しを登録すると、その部分は判定に数えません(例: 「女子高生だった頃」「子どもの頃の写真」)。18 歳未満の年齢をはっきり書いた指示は、登録があっても止めます。")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            HStack {
                TextField("数えない言い回し", text: $draft).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Button("登録") {
                    problem = ContentGuardSettings().add(draft)
                    if problem == nil { draft = ""; phrases = ContentGuardSettings().exceptions }
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let problem { Text(problem).font(.harness(.caption)).foregroundStyle(.orange) }
            ForEach(phrases, id: \.self) { phrase in
                HStack {
                    Text(phrase).font(.harness(.caption))
                    Button("外す") { ContentGuardSettings().remove(phrase); phrases = ContentGuardSettings().exceptions }.buttonStyle(.borderless)
                }
            }
        }
    }

    /// The core words (shown, fixed), then the words that are the user's: the app's defaults and the added ones, each
    /// removable, and a way back to the defaults.
    private func wordList(_ title: String, list: ContentGuardSettings.WordList, words: Binding<[String]>,
                          draft: Binding<String>) -> some View {
        let core = ContentGuardSettings.coreWords(list)
        let refresh = { words.wrappedValue = ContentGuardSettings().words(list) }
        return DisclosureGroup("\(title)(決めた言葉 \(words.wrappedValue.count) 語、固定 \(core.count) 語)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("固定: " + core.joined(separator: "、")).font(.harness(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("固定の言葉は、外すと未成年の線そのものが効かなくなる最低限のものです。ほかの言葉は自由に外したり足したりできます。")
                    .font(.harness(.caption2)).foregroundStyle(.secondary)
                HStack {
                    TextField("足す言葉", text: draft).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Button("足す") {
                        ContentGuardSettings().add(draft.wrappedValue, to: list)
                        draft.wrappedValue = ""
                        refresh()
                    }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("最初の状態に戻す") { ContentGuardSettings().restoreDefaults(list); refresh() }.buttonStyle(.borderless)
                }
                ForEach(words.wrappedValue, id: \.self) { word in
                    HStack {
                        Text(word).font(.harness(.caption))
                        Button("外す") { ContentGuardSettings().remove(word, from: list); refresh() }.buttonStyle(.borderless)
                    }
                }
                let removed = ContentGuardSettings().removedDefaults(list)
                if !removed.isEmpty {
                    Text("外した言葉: " + removed.joined(separator: "、") + "(足すと戻ります)")
                        .font(.harness(.caption2)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .font(.harness(.caption))
    }
}
