import HarnessCore

enum PrimaryInstructionIntentChecks {
    static func run() throws {
        let operations = [
            "このプロジェクトをテストしてね",
            "ビルドして、そのあとApple公式資料を検索して",
            "SafariのRefreshボタンを押して",
            "Appleの設計資料を調べてちょ",
            "Please run tests and search the web"
        ]
        for instruction in operations {
            try expect(
                PrimaryInstructionIntentRouter.route(instruction) == .computerOperation,
                "Explicit computer operation was not routed: \(instruction)"
            )
        }

        let conversations = [
            "続けよ",
            "テスト方法を考えて",
            "検索画面のデザインを直して",
            "ビルドエラーの原因を説明して",
            "まずテストして、失敗したところを修正して",
            "このアプリをもっと使いやすくして"
        ]
        for instruction in conversations {
            try expect(
                PrimaryInstructionIntentRouter.route(instruction) == .modelConversation,
                "Ordinary production conversation was diverted: \(instruction)"
            )
        }
        print("✓ Explicit test and search requests route without diverting ordinary conversation")
    }
}
