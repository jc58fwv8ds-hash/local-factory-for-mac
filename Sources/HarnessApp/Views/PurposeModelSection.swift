import HarnessCore
import SwiftUI

/// 「用途ごとのモデル」 in the model settings (2026-10-09): for 文章を書く and 画像を作る, the project's model (default) or an
/// option from the local catalog file. Nothing changes until the user picks something here.
struct PurposeModelSection: View {
    @State private var settings = PurposeModelSettings()
    @State private var chosen: [ModelPurpose: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("用途ごとのモデル", systemImage: "square.stack.3d.up").font(.harness(.headline))
            Text("入力欄で「文章を書く」「画像を作る」を選んだときに使うモデルです。既定ではプロジェクトのモデルを使います。")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            if settings.catalog == .empty {
                Text("追加のモデルの一覧(purpose-models.json)がありません。")
                    .font(.harness(.caption)).foregroundStyle(.secondary)
            } else {
                ForEach(ModelPurpose.allCases, id: \.self) { purpose in
                    picker(purpose)
                }
            }
        }
        .onAppear {
            for purpose in ModelPurpose.allCases { chosen[purpose] = settings.chosen(purpose)?.id ?? "" }
        }
    }

    private func picker(_ purpose: ModelPurpose) -> some View {
        let options = settings.catalog.options(for: purpose)
        let binding = Binding<String>(get: { chosen[purpose] ?? "" }, set: { id in
            chosen[purpose] = id
            settings.choose(id.isEmpty ? nil : id, for: purpose)
        })
        return VStack(alignment: .leading, spacing: 4) {
            Picker(purpose.title, selection: binding) {
                Text(purpose == .image ? "選ばない" : "プロジェクトのモデル(既定)").tag("")
                ForEach(options) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 420, alignment: .leading)
            if let note = options.first(where: { $0.id == chosen[purpose] })?.note {
                Text(note).font(.harness(.caption2)).foregroundStyle(.secondary)
            }
        }
    }
}
