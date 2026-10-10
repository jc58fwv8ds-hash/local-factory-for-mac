import HarnessCore
import SwiftUI

struct ReplySuggestionsView: View {
    let store: WorkspaceStore
    @State private var pendingReplacement: ReplySuggestion?

    private var session: ReplySuggestionSession { store.replySuggestions }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("次の頼み方に迷ったら", systemImage: "text.bubble")
                    .font(.harness(.subheadline, weight: .semibold))
                Spacer()
                if session.isLoading {
                    ProgressView().controlSize(.small)
                    Button("候補づくりを止める", action: session.cancel)
                        .accessibilityIdentifier(HarnessAccessibilityID.replySuggestionsCancel)
                } else {
                    Button(session.suggestions.isEmpty ? "案をいくつか出す" : "別の案を出す") {
                        store.generateReplySuggestions()
                    }
                    .accessibilityIdentifier(HarnessAccessibilityID.replySuggestionsGenerate)
                }
            }
            .font(.harness(.caption))

            Text(session.isLoading
                 ? "この会話に合う頼み方を考えています。待たずに下の欄から送っても大丈夫です。"
                 : "案を選ぶと下の入力欄に入ります。書き足して送っても、自分の言葉で頼んでも大丈夫。")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)

            if let message = session.message {
                Text(message)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(session.suggestions) { suggestion in
                    suggestionCard(suggestion)
                }
            }
            if !session.suggestions.isEmpty {
                Text("ローカルAIが考えた未送信の案です。選ぶだけでは作業や変更は実行しません。")
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
        .confirmationDialog("入力中の文章を、この案に置き換える？", isPresented: Binding(
            get: { pendingReplacement != nil },
            set: { if !$0 { pendingReplacement = nil } }
        ), titleVisibility: .visible) {
            if let pendingReplacement {
                Button("この案に置き換える") {
                    store.useReplySuggestion(pendingReplacement.id, replacingDraft: true)
                    self.pendingReplacement = nil
                }
                Button("入力中の文章を残す", role: .cancel) { self.pendingReplacement = nil }
            }
        } message: {
            Text("今の入力を残したい場合はキャンセルしてね。置き換えても、送るまでは作業を始めません。")
        }
    }

    private func suggestionCard(_ suggestion: ReplySuggestion) -> some View {
        let isInComposer = store.instruction == suggestion.instruction
        return Button {
            if store.useReplySuggestion(suggestion.id) == .confirmationRequired {
                pendingReplacement = suggestion
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(verbatim: suggestion.title)
                        .font(.harness(.subheadline, weight: .semibold))
                    Spacer(minLength: 4)
                    Image(systemName: isInComposer ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
                Text(verbatim: suggestion.instruction)
                    .font(.harness(.subheadline))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: suggestion.effect)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(isInComposer ? "入力欄に入っています" : "この案を入力欄へ")
                    .font(.harness(.caption2, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isInComposer ? Color.accentColor : Color.primary.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(HarnessAccessibilityID.replySuggestion(suggestion.id))
        .accessibilityHint("選ぶと入力欄に入ります。送信はしません。")
    }
}
