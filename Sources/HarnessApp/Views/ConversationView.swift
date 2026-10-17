import HarnessCore
import SwiftUI

struct ConversationView: View {
    @Bindable var store: WorkspaceStore

    /// Chat is the center of the project screen (2026-10-08): the whole history is shown; the enclosing ScrollView keeps
    /// the newest message in view.
    private var visibleMessages: ArraySlice<ConversationMessage> {
        store.project.conversation[...]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.project.selectedModel == nil {
                Label("AIモデルが未接続です。サイドバーの「AIモデル」から選んでください。", systemImage: "exclamationmark.circle")
                    .font(.harness(.caption, weight: .medium))
                    .foregroundStyle(.orange)
            }

            if let checkpoint = store.interruptedInferenceCheckpoint {
                InferenceResumeNotice(
                    checkpoint: checkpoint,
                    canResume: store.canResumeInterruptedInference,
                    onResume: store.resumeInterruptedInference,
                    onDiscard: store.discardInterruptedInference
                )
            }

            if visibleMessages.isEmpty && !store.isGeneratingSelectedProject {
                FactoryLogoView(height: 112)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                Text("下の入力欄から指示すると、選択中のローカルAIとの会話がここに保存されます。")
                    .font(.harness(.subheadline))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(visibleMessages) { message in
                        ConversationBubble(message: message, store: store)
                        if let change = store.chatChanges[message.id] {
                            ChatChangeCard(change: change, store: store)
                        }
                        if let rename = store.renameChanges[message.id] {
                            RenameChangeCard(change: rename, store: store)
                        }
                        if let word = store.wordChanges[message.id] {
                            WordChangeCard(change: word, store: store)
                        }
                        if let install = store.appInstallChanges[message.id] {
                            AppInstallCard(change: install, store: store)
                        }
                        if let pdf = store.pdfChanges[message.id] {
                            PDFChangeCard(change: pdf, store: store)
                        }
                        if let analysis = store.analysisChanges[message.id] {
                            AnalysisChangeCard(change: analysis)
                        }
                        if let sheet = store.spreadsheetChanges[message.id] {
                            SpreadsheetChangeCard(change: sheet, store: store)
                        }
                        if let image = store.imageChanges[message.id] {
                            ImageChangeCard(change: image)
                        }
                    }

                    if store.isGeneratingSelectedProject {
                        StreamingResponseBubble(
                            content: store.streamingResponse,
                            placeholder: store.generationStatusMessage
                        )
                    }
                }
                if let performance = store.visibleConversationPerformance {
                    ConversationPerformanceView(performance: performance)
                        .id(performance.responseID)
                }
                Text("分からない言葉に少しカーソルを合わせると、意味を説明します。右クリックからも開けます。")
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
                if store.replySuggestionContext != nil {
                    ReplySuggestionsView(store: store)
                }
            }
        }
        // No frame around the chat: it is the screen's main content, not one card among others (2026-10-08).
        .onChange(of: store.computerOperator.isBusy) { store.synchronizeReplySuggestions() }
        .onDisappear { store.replySuggestions.cancel() }
    }
}

private struct ConversationBubble: View {
    let message: ConversationMessage
    let store: WorkspaceStore

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 70) }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: messageSymbol)
                    Text(messageTitle)
                }
                .font(.harness(.caption, weight: .semibold))
                .foregroundStyle(.secondary)

                if message.role == .assistant {
                    ExplainedResponseText(
                        text: message.content,
                        model: store.project.selectedModel,
                        service: store.termExplanationService,
                        isSuspended: store.isGenerating || store.computerOperator.isBusy || store.replySuggestions.isLoading
                    )
                    .id(store.project.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(message.content)
                        .font(.harness(.subheadline))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .background(
                messageBackground,
                in: RoundedRectangle(cornerRadius: 13)
            )

            if message.role == .assistant { Spacer(minLength: 36) }
        }
    }

    private var messageSymbol: String {
        if message.origin == .externalReview {
            return "doc.text.magnifyingglass"
        }
        if message.origin == .remoteUser {
            return "iphone"
        }
        return message.role == .user ? "person.fill" : "sparkles"
    }

    private var messageTitle: String {
        if message.origin == .externalReview {
            return "外部レビュー（参考資料）"
        }
        if message.origin == .remoteUser {
            return "iPhoneからの指示"
        }
        return message.role == .user ? "あなた" : (message.modelName ?? "Local Factory")
    }

    private var messageBackground: Color {
        if message.origin == .externalReview {
            return Color.orange.opacity(0.08)
        }
        return message.role == .user
            ? Color.accentColor.opacity(0.12)
            : Color.primary.opacity(0.045)
    }
}

private struct StreamingResponseBubble: View {
    let content: String
    let placeholder: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 2)

            Text(content.isEmpty ? placeholder : content)
                .font(.harness(.subheadline))
                .foregroundStyle(content.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.accentColor.opacity(0.14)))
    }
}
