import Foundation

public enum TargetPlatform: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case macOS
    case iPhone
    case appleWatch = "Apple Watch"
    case web = "Web"

    public var id: String { rawValue }
}

public enum ProjectStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case concept = "構想"
    case design = "設計"
    case build = "制作"
    case test = "テスト"
    case finish = "仕上げ"
    case release = "リリース"

    public var id: String { rawValue }

    public var ordinal: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

public enum WorkStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case completed
    case active
    case pending
    case needsAttention

    public var id: String { rawValue }
}

public struct WorkItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var detail: String
    public var status: WorkStatus
    public var responseToMessageID: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        status: WorkStatus,
        responseToMessageID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.responseToMessageID = responseToMessageID
    }
}

public enum ActivityKind: String, Codable, Sendable {
    case information
    case change
    case verification
    case instruction
    case warning
}

public struct ActivityEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public var title: String
    public var detail: String
    public var kind: ActivityKind

    public init(
        id: UUID = UUID(),
        occurredAt: Date = .now,
        title: String,
        detail: String,
        kind: ActivityKind
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.title = title
        self.detail = detail
        self.kind = kind
    }
}

public struct ModelSelection: Codable, Equatable, Sendable {
    public var identifier: String
    public var displayName: String
    public var runtime: RuntimeKind
    public var capabilities: Set<VisualModelCapability>?

    public init(
        identifier: String,
        displayName: String,
        runtime: RuntimeKind,
        capabilities: Set<VisualModelCapability>? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.runtime = runtime
        self.capabilities = capabilities
    }
}

public enum ConversationRole: String, Codable, Sendable {
    case user
    case assistant
}

public enum ConversationOrigin: String, Codable, Sendable {
    case user
    case remoteUser
    case localModel
    case externalReview
}

public struct ConversationMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var role: ConversationRole
    public var content: String
    public var modelName: String?
    public var origin: ConversationOrigin
    public var visualAttachments: [VisualAttachmentDescriptor]

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        role: ConversationRole,
        content: String,
        modelName: String? = nil,
        origin: ConversationOrigin? = nil,
        visualAttachments: [VisualAttachmentDescriptor] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.role = role
        self.content = content
        self.modelName = modelName
        self.origin = origin ?? (role == .user ? .user : .localModel)
        self.visualAttachments = visualAttachments
    }
}

extension ConversationMessage {
    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case role
        case content
        case modelName
        case origin
        case visualAttachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(ConversationRole.self, forKey: .role)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            role: role,
            content: try container.decode(String.self, forKey: .content),
            modelName: try container.decodeIfPresent(String.self, forKey: .modelName),
            origin: try container.decodeIfPresent(
                ConversationOrigin.self,
                forKey: .origin
            ) ?? (role == .user ? .user : .localModel),
            visualAttachments: try container.decodeIfPresent(
                [VisualAttachmentDescriptor].self,
                forKey: .visualAttachments
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(modelName, forKey: .modelName)
        try container.encode(origin, forKey: .origin)
        if !visualAttachments.isEmpty {
            try container.encode(visualAttachments, forKey: .visualAttachments)
        }
    }
}

public struct HarnessProject: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var summary: String
    public var targets: [TargetPlatform]
    public var stage: ProjectStage
    public var progress: Double
    public var currentActivity: String
    public var workItems: [WorkItem]
    public var activity: [ActivityEvent]
    public var selectedModel: ModelSelection?
    public var conversation: [ConversationMessage]
    public var fileCheckpoints: [GitFileCheckpoint]
    public var repairResumeState: RepairResumeState?
    public var operationCheckpoint: ProjectOperationCheckpoint?
    public var computerOperationCheckpoint: ComputerOperationCheckpoint?
    public var creationLoop: CreationLoopState
    public var artifactCreationPlan: ArtifactCreationPlan?
    public var runCoordinator: RunCoordinatorState
    /// The project's conventions the user confirmed in the chat (2026-10-09, backlog #12): what they chose when an example
    /// of a change was wrong. They go with every later code-change instruction of this project. Optional so older saved
    /// projects still load.
    public var conventions: [String]?
    /// Instructions booked to run again at a fixed time (2026-10-11, backlog #43). Optional so older projects still load.
    public var scheduledInstructions: [ScheduledInstruction]?

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        targets: [TargetPlatform],
        stage: ProjectStage,
        progress: Double,
        currentActivity: String,
        workItems: [WorkItem],
        activity: [ActivityEvent],
        selectedModel: ModelSelection? = nil,
        conversation: [ConversationMessage] = [],
        fileCheckpoints: [GitFileCheckpoint] = [],
        repairResumeState: RepairResumeState? = nil,
        operationCheckpoint: ProjectOperationCheckpoint? = nil,
        computerOperationCheckpoint: ComputerOperationCheckpoint? = nil,
        creationLoop: CreationLoopState = CreationLoopState(),
        artifactCreationPlan: ArtifactCreationPlan? = nil,
        runCoordinator: RunCoordinatorState = RunCoordinatorState(),
        conventions: [String]? = nil,
        scheduledInstructions: [ScheduledInstruction]? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.targets = targets
        self.stage = stage
        self.progress = min(max(progress, 0), 1)
        self.currentActivity = currentActivity
        self.workItems = workItems
        self.activity = activity
        self.selectedModel = selectedModel
        self.conversation = conversation
        self.fileCheckpoints = fileCheckpoints
        self.repairResumeState = repairResumeState
        self.operationCheckpoint = operationCheckpoint
        self.computerOperationCheckpoint = computerOperationCheckpoint
        self.creationLoop = creationLoop
        self.artifactCreationPlan = artifactCreationPlan
        self.runCoordinator = runCoordinator
        self.conventions = conventions
        self.scheduledInstructions = scheduledInstructions
    }
}

public extension HarnessProject {
    static let starter = HarnessProject(
        name: "Personal Memory",
        summary: "Apple Watchで記録し、iPhoneを中継してMac上のローカルAIで一日の記憶へ編集するアプリ",
        targets: [.appleWatch, .iPhone, .macOS],
        stage: .design,
        progress: 0.28,
        currentActivity: "最初のプロダクト設計を整理しています",
        workItems: [
            WorkItem(
                title: "体験の中心を定義",
                detail: "録音ではなく『読み返せる記憶』を主役にする",
                status: .completed
            ),
            WorkItem(
                title: "端末間の役割を設計",
                detail: "Watch → iPhone → Mac の責務とデータ移動",
                status: .active
            ),
            WorkItem(
                title: "Watch録音PoC",
                detail: "連続録音・バッテリー・バックグラウンド転送を実機検証",
                status: .pending
            ),
            WorkItem(
                title: "ローカル解析パイプライン",
                detail: "文字起こし、重要度判定、Daily Record生成",
                status: .pending
            )
        ],
        activity: [
            ActivityEvent(
                title: "構想をプロジェクトへ変換しました",
                detail: "Personal Memoryを最初の制作対象として登録",
                kind: .information
            ),
            ActivityEvent(
                title: "安全原則を設定しました",
                detail: "削除・署名・公開は常に人の承認が必要です",
                kind: .verification
            )
        ]
    )
}
