import HarnessCore
import SwiftUI

struct NewProjectView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ProjectDraft()
    @State private var createsIPhoneApp = false
    @State private var productName = "HarnessRemote"
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
                    TextField("製品名（英数字）", text: $productName)
                    TextField("組織ID", text: $organizationIdentifier)
                }
                .textFieldStyle(.roundedBorder)
                Text("作成時に保存先フォルダを選びます。同名の項目は上書きしません。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("作成") {
                    if createsIPhoneApp {
                        if store.createIPhoneAppProjectChoosingDestination(
                            from: draft,
                            productName: productName,
                            organizationIdentifier: organizationIdentifier
                        ) {
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
        .padding(26)
        .frame(width: 610, height: createsIPhoneApp ? 570 : 500)
    }
}
