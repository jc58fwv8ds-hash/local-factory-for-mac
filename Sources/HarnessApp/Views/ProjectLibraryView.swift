import HarnessCore
import SwiftUI
import UniformTypeIdentifiers

struct ProjectLibraryView: View {
    @Bindable var store: WorkspaceStore

    @State private var searchText = ""
    @State private var scope: ProjectLibraryScope = .all
    @State private var sort: ProjectLibrarySort = .recent
    @State private var isImporting = false
    @State private var editTarget: ProjectRecord?
    @State private var trashTarget: ProjectRecord?
    @State private var removalTarget: ProjectRecord?
    @State private var importError: String?

    var body: some View {
        libraryContent
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: handleImport
            )
            .sheet(item: $editTarget) { record in
                EditProjectView(record: record) { draft in
                    store.updateProject(record.id, from: draft)
                }
            }
            .alert(
                "ゴミ箱へ移動しますか？",
                isPresented: trashAlertBinding,
                presenting: trashTarget,
                actions: trashAlertActions,
                message: trashAlertMessage
            )
            .alert(
                "一覧から削除しますか？",
                isPresented: removalAlertBinding,
                presenting: removalTarget,
                actions: removalAlertActions,
                message: removalAlertMessage
            )
            .alert("フォルダを読み込めませんでした", isPresented: importErrorBinding) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "不明なエラー")
            }
    }

    private var libraryContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ProjectLibraryHeader(
                    activeCount: store.library.activeRecords.count,
                    archivedCount: store.library.archivedRecords.count,
                    trashedCount: store.library.trashedRecords.count,
                    onImport: { isImporting = true },
                    onCreate: { store.isShowingNewProject = true }
                )

                ProjectLibraryControls(
                    searchText: $searchText,
                    scope: $scope,
                    sort: $sort
                )

                projectContent
            }
            .padding(32)
        }
        .background {
            LinearGradient(
                colors: [Color(nsColor: .controlBackgroundColor), Color.accentColor.opacity(0.025)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private var projectContent: some View {
        if visibleRecords.isEmpty {
            ProjectLibraryEmptyState(
                hasSearch: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onCreate: { store.isShowingNewProject = true }
            )
        } else {
            if !visibleActiveRecords.isEmpty {
                activeSection(records: visibleActiveRecords)
            }
            if !visibleArchivedRecords.isEmpty {
                lifecycleSection(
                    title: "アーカイブ",
                    subtitle: "休止中のプロジェクト",
                    records: visibleArchivedRecords
                )
            }
            if !visibleTrashedRecords.isEmpty {
                lifecycleSection(
                    title: "ゴミ箱",
                    subtitle: "Local Factoryの登録情報だけを保管。元のソースは削除されません。",
                    records: visibleTrashedRecords
                )
            }
        }
    }

    private func activeSection(records: [ProjectRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProjectSectionHeading(
                title: "制作中",
                subtitle: "\(records.count)件のアクティブなプロジェクト"
            )
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 285), spacing: 16)],
                spacing: 16
            ) {
                ForEach(records) { record in
                    ActiveProjectCard(
                        record: record,
                        isSelected: store.library.selectedProjectID == record.id,
                        onOpen: { store.selectProject(record.id) },
                        onEdit: { editTarget = record },
                        onArchive: { store.archiveProject(record.id) },
                        onTrash: { trashTarget = record }
                    )
                }
            }
        }
    }

    private func lifecycleSection(
        title: String,
        subtitle: String,
        records: [ProjectRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ProjectSectionHeading(title: title, subtitle: subtitle)
            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    LifecycleProjectRow(
                        record: record,
                        onRestore: { store.restoreProject(record.id) },
                        onTrash: { trashTarget = record },
                        onRemove: { removalTarget = record }
                    )
                    if index < records.count - 1 {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.quaternary))
        }
    }

    private var query: ProjectLibraryQuery {
        ProjectLibraryQuery(
            searchText: searchText,
            lifecycle: scope.lifecycle,
            sort: sort
        )
    }

    private var visibleRecords: [ProjectRecord] {
        store.library.records(matching: query)
    }

    private var visibleActiveRecords: [ProjectRecord] {
        visibleRecords.filter { $0.lifecycle == .active }
    }

    private var visibleArchivedRecords: [ProjectRecord] {
        visibleRecords.filter { $0.lifecycle == .archived }
    }

    private var visibleTrashedRecords: [ProjectRecord] {
        visibleRecords.filter { $0.lifecycle == .trashed }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            store.importProject(at: url)
        } catch {
            importError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func trashAlertActions(_ record: ProjectRecord) -> some View {
        Button("キャンセル", role: .cancel) { trashTarget = nil }
        Button("ゴミ箱へ移動", role: .destructive) {
            store.moveProjectToTrash(record.id)
            trashTarget = nil
        }
    }

    private func trashAlertMessage(_ record: ProjectRecord) -> Text {
        Text("「\(record.project.name)」をLocal Factoryの一覧から外します。元ファイルは削除しません。")
    }

    @ViewBuilder
    private func removalAlertActions(_ record: ProjectRecord) -> some View {
        Button("キャンセル", role: .cancel) { removalTarget = nil }
        Button("一覧から削除", role: .destructive) {
            store.removeProjectFromLibrary(record.id)
            removalTarget = nil
        }
    }

    private func removalAlertMessage(_ record: ProjectRecord) -> Text {
        Text("「\(record.project.name)」のLocal Factory内の登録情報を削除します。元のソースフォルダは残ります。")
    }

    private var trashAlertBinding: Binding<Bool> {
        Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } })
    }

    private var removalAlertBinding: Binding<Bool> {
        Binding(get: { removalTarget != nil }, set: { if !$0 { removalTarget = nil } })
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }
}
