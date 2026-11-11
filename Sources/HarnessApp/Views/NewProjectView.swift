import HarnessCore
import SwiftUI

struct NewProjectView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ProjectDraft()
    @State private var createsIPhoneApp = false
    @State private var productName = ""
    /// Follows the project name until the user types their own (2026-11-10).
    @State private var productNameEdited = false
    @State private var choosesFolder = false
    @State private var organizationIdentifier = "local.harness"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("新規プロジェクト")
                    .font(.harness(.title2, weight: .bold))
                    .accessibilityIdentifier(HarnessAccessibilityID.newProjectSheet)
                Text("アイデアと対象端末を登録します。あとから変更できます。")
                    .font(.harness(.subheadline))
                    .foregroundStyle(.secondary)
            }

            ProjectFormFields(draft: $draft, showsStage: false)

            Toggle("ビルド可能なiPhoneアプリ雛形も作成", isOn: $createsIPhoneApp)
                .font(.harness(.subheadline, weight: .medium))
                .accessibilityIdentifier(HarnessAccessibilityID.newProjectIPhoneTemplate)

            if createsIPhoneApp {
                HStack(spacing: 12) {
                    TextField("製品名（英数字）", text: Binding(get: { productName },
                                                            set: { productName = $0; productNameEdited = true }))
                        .accessibilityLabel("製品名")
                        .accessibilityIdentifier(HarnessAccessibilityID.newProjectProductName)
                    TextField("組織ID", text: $organizationIdentifier)
                        .accessibilityLabel("組織ID")
                }
                .textFieldStyle(.roundedBorder)
                Toggle("保存先のフォルダを自分で選ぶ", isOn: $choosesFolder)
                    .font(.harness(.caption))
                Text(choosesFolder ? "作成時に保存先フォルダを選びます。同名の項目は上書きしません。"
                     : "Local Factory のプロジェクト用フォルダに作ります。同名の項目は上書きしません。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("作成") {
                    if createsIPhoneApp {
                        let created = choosesFolder
                            ? store.createIPhoneAppProjectChoosingDestination(
                                from: draft, productName: productName, organizationIdentifier: organizationIdentifier)
                            : store.createIPhoneAppProjectInManagedFolder(
                                from: draft, productName: productName, organizationIdentifier: organizationIdentifier)
                        if created {
                            dismiss()
                        }
                    } else if store.createProject(from: draft) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !draft.isValid
                        || (createsIPhoneApp
                            && (productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || organizationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                )
                .accessibilityIdentifier(HarnessAccessibilityID.newProjectCreate)
            }
        }
        .onChange(of: draft.name, initial: true) { _, name in
            if !productNameEdited { productName = AppleAppProductName.suggested(from: name) }
        }
        .padding(26)
        .frame(width: 610, height: createsIPhoneApp ? 600 : 500)
    }
}
