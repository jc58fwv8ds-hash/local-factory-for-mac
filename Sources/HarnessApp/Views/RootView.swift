import AppKit
import HarnessCore
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: WorkspaceStore
    @State private var isShowingAppearanceSettings = false
    @AppStorage(StudioLayout.sidebarKey) private var isSidebarVisible = true
    @AppStorage(StudioLayout.inspectorKey) private var isInspectorVisible = false

    var body: some View {
        HStack(spacing: 0) {
            // The sidebar stays visible outside a project; inside one it opens and closes from the project bar.
            if isSidebarVisible || !store.hasSelectedProject || store.selectedSection != .home {
                SidebarView(
                    store: store,
                    onAppearance: { isShowingAppearanceSettings = true }
                )
                    .frame(width: 224)

                Divider().opacity(0.55)
            }

            if store.selectedSection == .apps {
                AppleAppLibraryView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selectedSection == .developer {
                DogfoodShadowView(sourcePath: store.library.selectedRecord?.sourceLocation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selectedSection == .voices {
                VoiceLibraryView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selectedSection == .projects {
                ProjectLibraryView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.hasSelectedProject && store.selectedProjectIsInMode {
                StudioView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isInspectorVisible {
                    Divider().opacity(0.55)

                    ActivityInspectorView(store: store)
                        .frame(width: 306)
                        .transition(.move(edge: .trailing))
                }
            } else {
                EmptyProjectView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $store.isShowingModelManager) {
            ModelManagerView(store: store)
        }
        .sheet(isPresented: $store.isShowingNewProject) {
            NewProjectView(store: store)
        }
        .sheet(isPresented: $store.isShowingComputerOperator) {
            ComputerOperatorView(store: store)
        }
        .sheet(isPresented: $isShowingAppearanceSettings) {
            AppearanceSettingsView()
        }
        .overlay(alignment: .top) {
            if let notice = store.notice {
                WorkspaceNoticeBanner(notice: notice, onDismiss: store.dismissNotice)
                    .frame(maxWidth: 560)
                    .padding(.top, 14)
                    .shadow(color: .black.opacity(0.09), radius: 12, y: 5)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.notice)
        .task { store.monitorSelectedSourceIfNeeded(minimumInterval: 0) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.monitorSelectedSourceIfNeeded()
            }
        }
    }
}

private struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    let onAppearance: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 11) {
                HarnessBrandIcon()

                VStack(alignment: .leading, spacing: 1) {
                    Text("Local Factory")
                        .font(.harness(size: 16, weight: .semibold))
                        .accessibilityIdentifier(HarnessAccessibilityID.root)
                    Text("for Mac")
                        .font(.harness(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)

            Picker("モード", selection: Binding(get: { store.workspaceMode }, set: { store.switchMode($0) })) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .accessibilityIdentifier(HarnessAccessibilityID.sidebarMode)

            VStack(spacing: 5) {
                SidebarButton(
                    title: "ホーム",
                    systemImage: "square.grid.2x2",
                    accessibilityID: HarnessAccessibilityID.sidebarHome,
                    isSelected: store.selectedSection == .home
                ) { store.selectedSection = .home }

                if store.workspaceMode == .code {
                SidebarButton(
                    title: "プロジェクト",
                    systemImage: "folder",
                    accessibilityID: HarnessAccessibilityID.sidebarProjects,
                    isSelected: store.selectedSection == .projects
                ) { store.selectedSection = .projects }

                SidebarButton(
                    title: "アプリ",
                    systemImage: "square.grid.3x3.square",
                    accessibilityID: HarnessAccessibilityID.sidebarApps,
                    isSelected: store.selectedSection == .apps
                ) { store.selectedSection = .apps }
                }

                SidebarButton(
                    title: "AIモデル",
                    systemImage: "brain.head.profile",
                    accessibilityID: HarnessAccessibilityID.sidebarModels,
                    isSelected: store.selectedSection == .models
                ) {
                    store.selectedSection = .models
                    store.isShowingModelManager = true
                }

                if store.workspaceMode == .chat {
                SidebarButton(
                    title: "声",
                    systemImage: "waveform",
                    accessibilityID: HarnessAccessibilityID.sidebarVoices,
                    isSelected: store.selectedSection == .voices
                ) {
                    store.openVoiceLibrary()
                }
                }
#if DEBUG
                if store.workspaceMode == .code {
                SidebarButton(
                    title: "開発",
                    systemImage: "hammer",
                    accessibilityID: "sidebar-developer",
                    isSelected: store.selectedSection == .developer
                ) { store.selectedSection = .developer }
                }
#endif
            }
            .padding(.horizontal, 10)

            HStack {
                Text(store.workspaceMode == .chat ? "チャット" : "制作中")
                    .font(.harness(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if store.workspaceMode == .chat { store.startNewChat() } else { store.isShowingNewProject = true }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help(store.workspaceMode == .chat ? "新しいチャット" : "新規プロジェクト")
                .accessibilityIdentifier(HarnessAccessibilityID.sidebarNewProject)
            }
            .padding(.horizontal, 16)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(store.modeRecords) { record in
                        ProjectSidebarRow(
                            record: record,
                            isSelected: store.library.selectedProjectID == record.id
                                && store.selectedSection == .home
                        ) {
                            store.selectProject(record.id)
                        }
                    }

                    if store.modeRecords.isEmpty {
                        Text(store.workspaceMode == .chat ? "チャットはありません(+ で始めます)" : "プロジェクトはありません")
                            .font(.harness(.caption))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(store.hasConfiguredModel ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(store.hasConfiguredModel ? "AI 接続済み" : "AI 未接続")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onAppearance) {
                    Image(systemName: "paintpalette")
                }
                .buttonStyle(.plain)
                .help("カラーと外観")
                .accessibilityIdentifier(HarnessAccessibilityID.sidebarAppearance)
                Button {
                    store.isShowingModelManager = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(HarnessAccessibilityID.sidebarModelManager)
            }
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
            .padding(12)
        }
        .background(.ultraThinMaterial)
    }
}

private struct HarnessBrandIcon: View {
    var body: some View {
        FactoryLogoView(height: 38)
            .accessibilityHidden(true)
    }
}

private struct ProjectSidebarRow: View {
    let record: ProjectRecord
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(isSelected ? 0.2 : 0.1))
                    .overlay {
                        Image(systemName: record.origin == .imported ? "folder.fill" : "hammer.fill")
                            .font(.harness(.caption))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 31, height: 31)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.project.name)
                        .font(.harness(.subheadline, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    Text(record.project.stage.rawValue)
                        .font(.harness(.caption2))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(HarnessAccessibilityID.sidebarProject(record.id))
    }
}

private struct SidebarButton: View {
    let title: String
    let systemImage: String
    let accessibilityID: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                Text(title)
                Spacer()
            }
            .font(.harness(size: 14, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
    }
}
