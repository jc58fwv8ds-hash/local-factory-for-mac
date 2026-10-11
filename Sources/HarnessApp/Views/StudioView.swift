import HarnessCore
import SwiftUI

struct StudioView: View {
    @Bindable var store: WorkspaceStore
    @State private var isShowingWorkPlanEditor = false
    @State private var isShowingWorkPlan = false
    @State private var isShowingPreview = false
    @State private var isShowingConventions = false
    @State private var isShowingSchedules = false
    @AppStorage(StudioLayout.sidebarKey) private var isSidebarVisible = true
    @AppStorage(StudioLayout.inspectorKey) private var isInspectorVisible = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.55)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ConversationView(store: store)
                        Color.clear.frame(height: 1).id(StudioLayout.bottomID)
                    }
                    .frame(maxWidth: StudioLayout.chatWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.project.conversation.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(StudioLayout.bottomID, anchor: .bottom) }
                }
                .onChange(of: store.streamingResponse) { _, _ in
                    proxy.scrollTo(StudioLayout.bottomID, anchor: .bottom)
                }
            }

            Divider().opacity(0.65)
            CommandComposer(store: store)
                .frame(maxWidth: StudioLayout.chatWidth + 48)
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $isShowingWorkPlanEditor) {
            WorkPlanEditorView(store: store)
        }
    }

    /// The logo's smoke rises while a reply is generated or a chat change is being made.
    private var isWorking: Bool {
        store.isGeneratingSelectedProject || store.chatChanges.values.contains { $0.status == .running }
    }

    /// The project's conventions (backlog #12): sent with every code-change instruction; each can be removed.
    private var conventionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("このプロジェクトの約束ごと").font(.harness(.headline))
            Text("修正を頼むたびに、AI への指示に添えます。違っていれば消してください。")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.project.conventions ?? [], id: \.self) { convention in
                        HStack(alignment: .top) {
                            Text(convention).font(.harness(.caption)).textSelection(.enabled)
                            Spacer()
                            Button { store.forgetConvention(convention) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                                .help("この約束ごとを消す")
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 420, height: 320)
    }

    private var scheduleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("予約した指示").font(.harness(.headline))
            Text("時間になると案をカードで出します。ファイルが変わるのは「適用する」を押したときだけです。")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.scheduledInstructions) { booking in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(booking.schedule.description).font(.harness(.caption)).bold()
                                Text(booking.instruction).font(.harness(.caption)).textSelection(.enabled)
                                if let next = booking.nextRun(after: max(Date(), booking.lastRun ?? booking.created)) {
                                    Text("次回 \(next.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.harness(.caption)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { store.cancelScheduledInstruction(booking.id) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                                .help("この予約を取り消す")
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 420, height: 320)
    }

    /// One slim bar instead of the large header: name, summary, stage, targets, and the panels that open on demand.
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { isSidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless)
                .help(isSidebarVisible ? "サイドバーを閉じる" : "サイドバーを開く")
            // The sidebar shows the logo with the name; the bar shows it (with its smoke while working) when the sidebar is closed.
            if !isSidebarVisible || isWorking {
                FactoryLogoView(isWorking: isWorking, height: 34)
                    .help(isWorking ? "処理中" : "Local Factory")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(store.project.name)
                    .font(.harness(.headline))
                    .lineLimit(1)
                Text(((store.project.selectedModel?.displayName).map { "\($0) · " } ?? "") + store.project.summary)
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(store.project.stage.rawValue)
                .font(.harness(.caption, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
            ForEach(store.project.targets) { target in
                Image(systemName: symbol(for: target))
                    .foregroundStyle(.secondary)
                    .help(target.rawValue)
            }
            if let conventions = store.project.conventions, !conventions.isEmpty {
                Button { isShowingConventions.toggle() } label: { Label("約束ごと \(conventions.count)", systemImage: "list.bullet.rectangle") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("例の確認で「違う」と答えたときに覚えた、このプロジェクトの決まり")
                    .popover(isPresented: $isShowingConventions, arrowEdge: .bottom) { conventionList }
            }
            if !store.scheduledInstructions.isEmpty {
                Button { isShowingSchedules.toggle() } label: { Label("予約 \(store.scheduledInstructions.count)", systemImage: "clock") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("「毎朝8時に…」のように頼んで予約した指示")
                    .popover(isPresented: $isShowingSchedules, arrowEdge: .bottom) { scheduleList }
            }
            Button { isShowingWorkPlan.toggle() } label: {
                Label("作業計画 \(Int(store.project.progress * 100))%", systemImage: "checklist")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $isShowingWorkPlan, arrowEdge: .bottom) {
                ScrollView { workPlan.padding(16) }.frame(width: 420, height: 460)
            }
            Button { isShowingPreview.toggle() } label: { Label("プレビュー", systemImage: "eye") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $isShowingPreview, arrowEdge: .bottom) {
                    ScrollView { ProductPreview().padding(16) }.frame(width: 460, height: 420)
                }
            Button { store.openComputerOperator() } label: { Image(systemName: "desktopcomputer.and.macbook") }
                .buttonStyle(.borderless)
                .help("Computer")
                .accessibilityIdentifier(HarnessAccessibilityID.computerOperatorOpen)
            Button { isInspectorVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless)
                .help(isInspectorVisible ? "詳細パネルを閉じる" : "詳細パネルを開く")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var workPlan: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("現在の制作計画")
                    .font(.harness(.headline))
                Spacer()
                Button {
                    isShowingWorkPlanEditor = true
                } label: {
                    Label("編集", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isGeneratingSelectedProject)
                Text("\(Int(store.project.progress * 100))%")
                    .font(.harness(.subheadline, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(store.project.workItems.enumerated()), id: \.element.id) { index, item in
                    WorkItemRow(item: item)
                    if index < store.project.workItems.count - 1 {
                        Divider().padding(.leading, 43)
                    }
                }
            }
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.quaternary))
        }
    }

    private func symbol(for platform: TargetPlatform) -> String {
        switch platform {
        case .macOS: "macbook"
        case .iPhone: "iphone"
        case .appleWatch: "applewatch"
        case .web: "globe"
        }
    }
}

/// Layout of the chat-centered project screen (2026-10-08).
enum StudioLayout {
    static let sidebarKey = "ui.studio.sidebarVisible"
    static let inspectorKey = "ui.studio.inspectorVisible"
    static let chatWidth: CGFloat = 760
    static let bottomID = "studio.chat.bottom"
}
