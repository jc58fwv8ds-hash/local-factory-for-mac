import Foundation
import HarnessCore

extension WorkspaceStore {
    @discardableResult
    func createManagedIPhoneAppSource(
        for projectID: UUID,
        productName: String,
        organizationIdentifier: String
    ) -> Bool {
        do {
            return createIPhoneAppSource(
                for: projectID,
                parentDirectory: try managedProjectDirectory.prepare(),
                productName: productName,
                organizationIdentifier: organizationIdentifier
            )
        } catch {
            presentNotice(error.localizedDescription, kind: .error)
            return false
        }
    }

    @discardableResult
    private func createIPhoneAppSource(
        for projectID: UUID,
        parentDirectory: URL,
        productName: String,
        organizationIdentifier: String
    ) -> Bool {
        guard let record = library.records.first(where: { $0.id == projectID }) else {
            presentNotice("プロジェクトを確認できませんでした", kind: .error)
            return false
        }
        guard record.sourceLocation == nil else {
            presentNotice("このプロジェクトにはソースが接続済みです", kind: .error)
            return false
        }
        do {
            let result = try appleAppScaffolder.create(
                AppleAppScaffoldRequest(
                    parentDirectoryPath: parentDirectory.path,
                    productName: productName.trimmingCharacters(in: .whitespacesAndNewlines),
                    displayName: record.project.name,
                    organizationIdentifier: organizationIdentifier.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )
            )
            guard library.connectSource(at: result.rootPath, to: projectID) else {
                presentNotice(
                    "雛形は作成しましたが、Local Factoryへ接続できませんでした。作成先を確認してください。",
                    kind: .error
                )
                return false
            }
            sourceChangeSummaries.removeValue(forKey: projectID)
            persist(successMessage: "iPhoneアプリの土台を作成して接続しました")
            inspectSource(for: projectID, announcesCompletion: false, detectsChanges: false)
            return true
        } catch {
            presentNotice(error.localizedDescription, kind: .error)
            return false
        }
    }

    @discardableResult
    func createIPhoneAppProjectChoosingDestination(
        from draft: ProjectDraft,
        productName: String,
        organizationIdentifier: String
    ) -> Bool {
        guard let parent = directorySelector.chooseDirectory(
            message: "この中に新しい\(productName)フォルダを作成します。既存項目は上書きしません。",
            prompt: "この場所に作成"
        ) else { return false }
        return createIPhoneAppProject(
            from: draft,
            parentDirectory: parent,
            productName: productName,
            organizationIdentifier: organizationIdentifier
        )
    }

    @discardableResult
    func createIPhoneAppProject(
        from draft: ProjectDraft,
        parentDirectory: URL,
        productName: String,
        organizationIdentifier: String
    ) -> Bool {
        do {
            let result = try appleAppScaffolder.create(
                AppleAppScaffoldRequest(
                    parentDirectoryPath: parentDirectory.path,
                    productName: productName.trimmingCharacters(in: .whitespacesAndNewlines),
                    displayName: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    organizationIdentifier: organizationIdentifier.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )
            )
            var iPhoneDraft = draft
            iPhoneDraft.targets = [.iPhone]
            let record = try ProjectFactory().makeRecord(
                from: iPhoneDraft,
                sourceLocation: result.rootPath
            )
            library.add(record)
            selectedSection = .home
            persist(successMessage: "iPhoneアプリ「\(record.project.name)」の雛形を作成しました")
            inspectSource(for: record.id, announcesCompletion: false, detectsChanges: false)
            return true
        } catch {
            presentNotice(error.localizedDescription, kind: .error)
            return false
        }
    }
}
