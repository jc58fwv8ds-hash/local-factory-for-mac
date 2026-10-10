import SwiftUI

struct ExistingProjectAppStarterView: View {
    let projectName: String
    let onCreate: (String, String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var productName: String
    @State private var organizationIdentifier = "local.harness"

    init(projectName: String, onCreate: @escaping (String, String) -> Bool) {
        self.projectName = projectName
        self.onCreate = onCreate
        _productName = State(initialValue: Self.productName(from: projectName))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("iPhoneアプリの土台")
                    .font(.harness(.title2, weight: .bold))
                Text("\(projectName)へ、ビルドできるSwiftUIアプリを安全に作成して接続します。")
                    .font(.harness(.subheadline))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("製品名")
                    .font(.harness(.caption, weight: .semibold))
                TextField("英字で始まる英数字", text: $productName)
                    .textFieldStyle(.roundedBorder)
                Text("アプリ名とXcodeプロジェクト名に使います。")
                    .font(.harness(.caption2))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("組織ID")
                    .font(.harness(.caption, weight: .semibold))
                TextField("例: local.harness", text: $organizationIdentifier)
                    .textFieldStyle(.roundedBorder)
            }

            Label("作成・保管・接続・診断までLocal Factoryが安全に行います", systemImage: "wand.and.stars")
                .font(.harness(.caption))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("作成") {
                    if onCreate(productName, organizationIdentifier) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || organizationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(26)
        .frame(width: 520, height: 430)
    }

    private static func productName(from projectName: String) -> String {
        let alphanumeric = projectName.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII
        }
        let candidate = String(String.UnicodeScalarView(alphanumeric))
        guard let first = candidate.first, first.isLetter, candidate.count >= 3 else {
            return "HarnessApp"
        }
        return String(candidate.prefix(40))
    }
}
