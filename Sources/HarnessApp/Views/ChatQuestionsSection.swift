import SwiftUI

/// Before building: the builder's questions with an answer field each. Blank answers are left to the builder (おまかせ).
struct ChatQuestionsSection: View {
    let change: ChatChange
    @Bindable var store: WorkspaceStore
    @State private var answers: [String] = []

    var body: some View {
        if change.questions.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("作り始める前に、読み方で結果が変わる点がないか確かめています。")
                    .font(.harness(.caption)).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("作り始める前に確かめたい点です。分かるところだけ答えてください(空欄はおまかせ)。")
                    .font(.harness(.caption)).foregroundStyle(.secondary)
                ForEach(Array(change.questions.enumerated()), id: \.offset) { index, point in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(index + 1). \(point.question)").font(.harness(.caption)).textSelection(.enabled)
                        TextField("答え(例: はい / いいえ、〜です)", text: binding(index))
                            .textFieldStyle(.roundedBorder).font(.harness(.caption))
                            .accessibilityIdentifier(HarnessAccessibilityID.chatQuestionAnswer(index))
                    }
                }
                HStack {
                    Button("この答えで作る") { store.buildWithAnswers(change, answers: answers) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(HarnessAccessibilityID.chatQuestionBuild)
                    Button("おまかせで作る") { store.buildWithAnswers(change, answers: []) }
                        .accessibilityIdentifier(HarnessAccessibilityID.chatQuestionSkip)
                    Spacer()
                    Button("やめる", role: .cancel) { store.discardChatChange(change) }
                }
            }
        }
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(get: { index < answers.count ? answers[index] : "" },
                set: { value in
                    while answers.count <= index { answers.append("") }
                    answers[index] = value
                })
    }
}
