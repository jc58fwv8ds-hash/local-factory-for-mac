import SwiftUI

@MainActor
struct ContentView: View {
    @State private var session = RemoteSession()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RemoteDesign.pageSpacing) {
                    ConnectionStatusCard(session: session)
                    PairingCard(session: session)
                    if session.state == .connected {
                        InstructionCard(session: session)
                    }
                    if let receipt = session.lastReceipt {
                        ReceiptCard(receipt: receipt)
                    }
                    PrivacyNote()
                }
                .frame(maxWidth: RemoteDesign.maximumReadableWidth)
                .padding(.horizontal, RemoteDesign.pagePadding)
                .padding(.vertical, RemoteDesign.cardSpacing)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Harness Remote")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct ConnectionStatusCard: View {
    let session: RemoteSession

    var body: some View {
        RemoteCard {
            HStack(alignment: .top, spacing: RemoteDesign.cardSpacing) {
                Image(systemName: session.state.systemImage)
                    .font(.title2)
                    .foregroundStyle(session.state.tint)
                    .frame(
                        width: RemoteDesign.minimumTapTarget,
                        height: RemoteDesign.minimumTapTarget
                    )
                    .background(session.state.tint.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(session.state.title)
                        .font(.headline)
                    Text(session.statusMessage)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let peerName = session.connectedPeerName {
                        Label(peerName, systemImage: "desktopcomputer")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("接続状態、\(session.state.title)。\(session.statusMessage)")
        }
    }
}

private struct PairingCard: View {
    @Bindable var session: RemoteSession
    @FocusState private var isCodeFocused: Bool

    private var isConnecting: Bool {
        session.state == .searching || session.state == .connecting
    }

    private var hasActiveConnection: Bool {
        isConnecting || session.state == .connected
    }

    var body: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: RemoteDesign.cardSpacing) {
                Label("Macと接続", systemImage: "lock.shield")
                    .font(.headline)
                Text("Mac版Harnessで「リモート指示を許可」をオンにし、表示されたコードを入力します。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("000000", text: $session.pairingCode)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($isCodeFocused)
                    .padding(.horizontal, 16)
                    .frame(minHeight: RemoteDesign.primaryButtonHeight)
                    .background(
                        Color(uiColor: .tertiarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.quaternary)
                    }
                    .disabled(hasActiveConnection)
                    .accessibilityLabel("6桁のペアリングコード")
                    .onChange(of: session.pairingCode) { _, newValue in
                        let digits = newValue.filter { "0123456789".contains($0) }
                        let limited = String(digits.prefix(6))
                        if limited != newValue { session.pairingCode = limited }
                    }

                if hasActiveConnection {
                    Button(role: .cancel) {
                        session.disconnect()
                    } label: {
                        Label(
                            session.state == .connected ? "接続を終了" : "検索を中止",
                            systemImage: "xmark.circle"
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: RemoteDesign.minimumTapTarget)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        isCodeFocused = false
                        session.connect()
                    } label: {
                        Label("Harnessへ接続", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: RemoteDesign.minimumTapTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(session.pairingCode.count != 6)
                }
            }
        }
    }
}

private struct InstructionCard: View {
    @Bindable var session: RemoteSession
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: RemoteDesign.cardSpacing) {
                Label("制作指示", systemImage: "text.bubble")
                    .font(.headline)
                Text("普段の言葉で入力してください。HarnessがAI向けの指示へ整えます。")
                    .font(.body)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $session.instruction)
                        .font(.body)
                        .focused($isEditorFocused)
                        .frame(minHeight: 150)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .onChange(of: session.instruction) { _, newValue in
                            if newValue.count > RemoteProtocol.maximumInstructionCharacters {
                                session.instruction = String(
                                    newValue.prefix(RemoteProtocol.maximumInstructionCharacters)
                                )
                            }
                        }
                    if session.instruction.isEmpty {
                        Text("例：設定画面にダークモードを追加して")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.quaternary)
                }

                HStack {
                    Text("\(session.instruction.count) / \(RemoteProtocol.maximumInstructionCharacters)文字")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if session.isSending {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("送信中")
                    }
                }

                Button {
                    isEditorFocused = false
                    session.sendInstruction()
                } label: {
                    Label("制作指示を送信", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: RemoteDesign.minimumTapTarget)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!session.canSend)
            }
        }
    }
}

private struct ReceiptCard: View {
    let receipt: RemoteInstructionReceipt

    var body: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(receipt.status.title, systemImage: receipt.status.systemImage)
                    .font(.headline)
                    .foregroundStyle(receipt.status.tint)
                Text(receipt.message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(receipt.receivedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct PrivacyNote: View {
    var body: some View {
        Label {
            Text("接続コードと制作指示は保存せず、同じローカルネットワーク内の暗号化接続だけで送ります。")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "hand.raised.fill")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}
