import Foundation

public struct ProjectDraft: Equatable, Sendable {
    public var name: String
    public var summary: String
    public var targets: [TargetPlatform]
    public var stage: ProjectStage

    public init(
        name: String = "",
        summary: String = "",
        targets: [TargetPlatform] = [.macOS],
        stage: ProjectStage = .concept
    ) {
        self.name = name
        self.summary = summary
        self.targets = targets
        self.stage = stage
    }

    public init(project: HarnessProject) {
        self.init(
            name: project.name,
            summary: project.summary,
            targets: project.targets,
            stage: project.stage
        )
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ProjectFactoryError: LocalizedError, Sendable {
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "プロジェクト名を入力してください。"
        }
    }
}

public struct ProjectFactory: Sendable {
    public init() {}

    public func makeRecord(
        from draft: ProjectDraft,
        origin: ProjectOrigin = .createdInHarness,
        sourceLocation: String? = nil
    ) throws -> ProjectRecord {
        let cleanedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { throw ProjectFactoryError.emptyName }

        let project = HarnessProject(
            name: cleanedName,
            summary: draft.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            targets: normalizedTargets(draft.targets),
            stage: draft.stage,
            progress: draft.stage == .concept ? 0.06 : 0,
            currentActivity: "構想を整理する準備ができました",
            workItems: [
                WorkItem(
                    title: "目的と利用者を整理",
                    detail: "何を、誰のために作るかを会話から明確にします",
                    status: .active
                ),
                WorkItem(
                    title: "最初のバージョンを定義",
                    detail: "小さく動かせるMVPの範囲を決めます",
                    status: .pending
                )
            ],
            activity: [
                ActivityEvent(
                    title: origin == .imported ? "既存プロジェクトを読み込みました" : "プロジェクトを作成しました",
                    detail: sourceLocation ?? cleanedName,
                    kind: .information
                )
            ]
        )

        return ProjectRecord(
            project: project,
            origin: origin,
            sourceLocation: sourceLocation
        )
    }

    private func normalizedTargets(_ targets: [TargetPlatform]) -> [TargetPlatform] {
        let selected = Set(targets)
        let ordered = TargetPlatform.allCases.filter(selected.contains)
        return ordered.isEmpty ? [.macOS] : ordered
    }
}

public struct ProjectSourceAnalyzer {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func inferredTargets(at url: URL) -> [TargetPlatform] {
        let names = ((try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).map { $0.lastPathComponent.lowercased() }

        var targets = Set<TargetPlatform>()
        if names.contains(where: { $0 == "package.json" || $0 == "index.html" }) {
            targets.insert(.web)
        }
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0 == "package.swift" }) {
            targets.insert(.macOS)
        }
        if names.contains(where: { $0.contains("ios") || $0.contains("iphone") }) {
            targets.insert(.iPhone)
        }
        if names.contains(where: { $0.contains("watch") }) {
            targets.insert(.appleWatch)
        }
        return targets.isEmpty ? [.macOS] : TargetPlatform.allCases.filter(targets.contains)
    }
}

public enum ProjectLibrarySort: String, CaseIterable, Identifiable, Sendable {
    case recent = "最近開いた順"
    case name = "名前順"
    case progress = "進捗順"

    public var id: String { rawValue }
}

public struct ProjectLibraryQuery: Equatable, Sendable {
    public var searchText: String
    public var lifecycle: ProjectLifecycle?
    public var sort: ProjectLibrarySort

    public init(
        searchText: String = "",
        lifecycle: ProjectLifecycle? = nil,
        sort: ProjectLibrarySort = .recent
    ) {
        self.searchText = searchText
        self.lifecycle = lifecycle
        self.sort = sort
    }
}
