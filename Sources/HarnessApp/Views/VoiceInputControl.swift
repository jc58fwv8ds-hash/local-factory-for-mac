import HarnessCore
import SwiftUI

struct VoiceInputControl: View {
    @Bindable var store: WorkspaceStore

    private var session: VoiceCaptureSession { store.voiceCapture }

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                Text("入力")
                    .font(.harness(.caption2, weight: .semibold))
            }
            .foregroundStyle(iconColor)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(backgroundColor, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(VoicePressButtonStyle { isPressed in
            if isPressed {
                store.beginVoiceInput()
            } else {
                store.endVoiceInput()
            }
        })
        .disabled(store.isGenerating || store.voiceConversation.isActive)
        .help(helpText)
        .accessibilityLabel("押している間、音声を下書きへ入力")
        .accessibilityValue(session.message)
        .accessibilityIdentifier(HarnessAccessibilityID.commandVoicePushToTalk)
    }

    private var iconName: String {
        if session.availability == .requiresMacOS26 { return "mic.slash" }
        return session.isPressed ? "waveform" : "mic"
    }

    private var iconColor: Color {
        switch session.phase {
        case .listening: .white
        case .failed: .red
        default: .primary
        }
    }

    private var backgroundColor: Color {
        session.phase == .listening ? .accentColor : .secondary.opacity(0.12)
    }

    private var helpText: String {
        guard session.availability == .available else {
            return "音声入力にはmacOS 26以降が必要です"
        }
        return session.microphoneAuthorization.pushToTalkHelp
    }
}

struct VoiceConversationControl: View {
    @Bindable var store: WorkspaceStore

    private var session: VoiceConversationSession { store.voiceConversation }

    var body: some View {
        Button {
            store.toggleVoiceConversation()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: controlIcon)
                Text(controlLabel)
                    .font(.harness(.caption2, weight: .semibold))
            }
            .foregroundStyle(session.isActive ? .white : .primary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(session.isActive ? Color.accentColor : .secondary.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!session.isActive && cannotStart)
        .help(controlHelp)
        .accessibilityLabel(controlHelp)
        .accessibilityValue(session.message)
        .accessibilityIdentifier(HarnessAccessibilityID.commandVoiceConversation)
    }

    private var cannotStart: Bool {
        store.interactionBlocker(for: .startVoiceConversation) != nil
            || store.voiceCapture.isPressed
            || store.voiceCapture.phase == .listening
            || store.voiceCapture.phase == .transcribing
    }

    private var controlLabel: String {
        if session.phase == .speaking { return "話す" }
        return session.isActive
            ? "終了"
            : "会話・\(store.voiceLibrary.selectedProfile.displayName)"
    }

    private var controlIcon: String {
        if session.phase == .speaking { return "mic.fill" }
        return session.isActive ? "waveform.circle.fill" : "waveform.circle"
    }

    private var controlHelp: String {
        if session.phase == .speaking { return "読み上げを止めて話す。声での割り込みもできます" }
        if session.isActive { return "ボイスモードを終了" }
        guard session.availability == .available else {
            return "ボイスモードにはmacOS 26以降が必要です"
        }
        if let blocker = store.interactionBlocker(for: .startVoiceConversation) {
            return store.interactionMessage(for: blocker)
        }
        return "\(store.voiceLibrary.selectedProfile.displayName)で、"
            + session.microphoneAuthorization.conversationHelp
    }
}

struct VoiceConversationStatus: View {
    @Bindable var store: WorkspaceStore

    private var session: VoiceConversationSession { store.voiceConversation }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: statusIcon)
                .foregroundStyle(session.phase == .failed ? .red : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(phaseLabel)
                    .font(.harness(.caption2, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(session.message)
                    .font(.harness(.caption2, weight: .semibold))
                if let text = session.transcript?.text, !text.isEmpty {
                    Text(text)
                        .font(.harness(.caption2))
                        .foregroundStyle(
                            session.transcript?.stability == .volatile
                                ? .secondary
                                : .primary
                        )
                        .lineLimit(2)
                }
                if let metrics = session.lastMetrics {
                    Text("直前：\(VoiceConversationMetricsFormatter.summary(for: metrics))")
                        .font(.harness(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if session.isActive {
                Text("端末内音声")
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
            }
            Button {
                if session.isActive {
                    store.toggleVoiceConversation()
                } else {
                    store.dismissVoiceConversationStatus()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                    if session.isActive {
                        Text("終了")
                    }
                }
                .font(.harness(.caption2, weight: .bold))
                .padding(.horizontal, session.isActive ? 7 : 2)
                .frame(height: 24)
                .background(.secondary.opacity(session.isActive ? 0.12 : 0), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(session.isActive ? "ボイスモードを終了" : "閉じる")
            .accessibilityIdentifier(HarnessAccessibilityID.commandVoiceConversationStop)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
    }

    private var statusIcon: String {
        switch session.phase {
        case .listening: "ear"
        case .thinking: "sparkles"
        case .speaking: "speaker.wave.2.fill"
        case .failed: "exclamationmark.circle"
        default: "waveform"
        }
    }

    private var phaseLabel: String {
        let state = switch session.phase {
        case .listening: "あなたの番"
        case .transcribing: "言葉を確認中"
        case .thinking: "Local Factoryが考え中"
        case .speaking: "Local Factoryが話しています"
        case .interrupted: "割り込みました"
        case .failed: "確認が必要"
        default: "音声会話"
        }
        return "\(store.voiceLibrary.selectedProfile.displayName)・\(state)"
    }
}

struct VoiceTranscriptStatus: View {
    @Bindable var store: WorkspaceStore

    private var session: VoiceCaptureSession { store.voiceCapture }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.message)
                    .font(.harness(.caption2, weight: .semibold))
                if let text = session.transcript?.text, !text.isEmpty {
                    Text(text)
                        .font(.harness(.caption2))
                        .foregroundStyle(
                            session.transcript?.stability == .volatile
                                ? .secondary
                                : .primary
                        )
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button {
                if session.isPressed || session.phase == .listening || session.phase == .transcribing {
                    store.cancelVoiceInput()
                } else {
                    store.dismissVoiceStatus()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.harness(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(session.isPressed ? "音声入力を取り消す" : "閉じる")
            .accessibilityIdentifier(HarnessAccessibilityID.commandVoiceCancel)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
    }

    private var statusIcon: String {
        switch session.phase {
        case .listening: "waveform"
        case .failed: "exclamationmark.circle"
        case .reviewingTranscript: "checkmark.circle"
        default: "mic"
        }
    }

    private var statusColor: Color {
        switch session.phase {
        case .failed: .red
        case .reviewingTranscript: .green
        default: .accentColor
        }
    }
}

private struct VoicePressButtonStyle: ButtonStyle {
    let onPressChanged: @MainActor (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChanged(isPressed)
            }
    }
}
