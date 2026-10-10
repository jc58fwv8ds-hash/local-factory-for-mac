import HarnessCore

enum WorkPlanChecks {
    static func run() throws {
        var project = HarnessProject(
            name: "Plan Check",
            summary: "",
            targets: [.macOS],
            stage: .build,
            progress: 0.4,
            currentActivity: "",
            workItems: [],
            activity: []
        )

        let firstID = try ProjectWorkPlanWorkflow.add(
            WorkItemDraft(title: "  画面を作る  ", detail: "  SwiftUI  ", status: .active),
            to: &project
        )
        let secondID = try ProjectWorkPlanWorkflow.add(
            WorkItemDraft(title: "テストを書く", status: .pending),
            to: &project
        )
        try expect(
            project.workItems.map(\.title) == ["画面を作る", "テストを書く"]
                && project.workItems[0].detail == "SwiftUI",
            "Work-plan items were not normalized or added"
        )

        try ProjectWorkPlanWorkflow.update(
            secondID,
            from: WorkItemDraft(title: "回帰テストを書く", detail: "Core", status: .active),
            in: &project
        )
        try ProjectWorkPlanWorkflow.move(secondID, by: -1, in: &project)
        try ProjectWorkPlanWorkflow.setStatus(.completed, for: firstID, in: &project)
        try expect(
            project.workItems.map(\.id) == [secondID, firstID]
                && project.workItems[0].title == "回帰テストを書く"
                && project.workItems[1].status == .completed
                && project.activity.count == 5,
            "Work-plan editing, ordering, or status transitions failed"
        )

        try ProjectWorkPlanWorkflow.remove(firstID, from: &project)
        try expect(
            project.workItems.map(\.id) == [secondID]
                && project.activity.first?.title == "制作計画から削除しました",
            "Work-plan removal failed"
        )

        do {
            _ = try ProjectWorkPlanWorkflow.add(WorkItemDraft(title: "   "), to: &project)
            throw CheckFailure(description: "Empty work-plan title must fail")
        } catch ProjectWorkPlanError.emptyTitle {
            // Expected.
        }

        print("✓ Work-plan add, edit, ordering, status, validation, and removal are isolated")
    }
}
