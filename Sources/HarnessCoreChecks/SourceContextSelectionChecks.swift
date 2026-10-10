import HarnessCore

enum SourceContextSelectionChecks {
    static func run() throws {
        let files = [
            SourceContextFile(
                relativePath: "Sources/ContentView.swift",
                content: "struct ContentView {}",
                wasTruncated: false
            ),
            SourceContextFile(
                relativePath: "Sources/DesignSystem.swift",
                content: "enum DesignSystem {}",
                wasTruncated: false
            ),
            SourceContextFile(
                relativePath: "Tests/ContentViewTests.swift",
                content: "ContentViewを検査する",
                wasTruncated: false
            )
        ]
        let source = SourceContextSnapshot(
            files: files,
            totalCharacters: files.reduce(0) { $0 + $1.content.count },
            wasTruncated: false,
            skippedCandidateCount: 0
        )

        let responseOnly = SourceContextSelectionPolicy.select(
            source,
            for: project("今の返答を短い2文で言い直して。まだファイルは変えないでね")
        )
        let continuation = SourceContextSelectionPolicy.select(
            source,
            for: project("制作を継続")
        )
        let focused = SourceContextSelectionPolicy.select(
            source,
            for: project("ContentView.swiftの役割を教えて")
        )
        try expect(
            responseOnly.strategy == .omittedForResponseRevision
                && responseOnly.snapshot == nil
                && continuation.strategy == .allAvailable
                && continuation.snapshot == source
                && focused.strategy == .focused
                && focused.snapshot?.files.map(\.relativePath) == [
                    "Sources/ContentView.swift", "Tests/ContentViewTests.swift"
                ],
            "Conversation source selection was not conservative and bounded"
        )
        print("✓ Response-only prompts omit source while continuations and explicit files stay grounded")
    }

    private static func project(_ instruction: String) -> HarnessProject {
        HarnessProject(
            name: "Fixture",
            summary: "Selection checks",
            targets: [.macOS],
            stage: .design,
            progress: 0,
            currentActivity: "相談中",
            workItems: [],
            activity: [],
            conversation: [ConversationMessage(role: .user, content: instruction)]
        )
    }
}
