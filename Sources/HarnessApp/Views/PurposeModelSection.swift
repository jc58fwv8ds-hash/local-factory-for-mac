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
            Text("チャットの入力欄で「文章を書く」「画像を作る」「動画を作る」を選んだときに使うモデルです。印の付いたモデルは安全のための制限が少ないものです。コードのモードでは使いません。")
                .font(.harness(.caption)).foregroundStyle(.secondary)
            if settings.catalog == .empty {
                Text("追加のモデルの一覧(purpose-models.json)がありません。")
                    .font(.harness(.caption)).foregroundStyle(.secondary)
            } else {
                ForEach(ModelPurpose.allCases.filter { $0 != .video || !settings.catalog.options(for: .video).isEmpty },
                        id: \.self) { purpose in
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
                Text(purpose == .writing ? "プロジェクトのモデル(既定)" : "選ばない").tag("")
                ForEach(options) { option in
                    // A menu item shows text only: the mark goes in front of the name; the colored badge is shown below.
                    Text((option.badge.map { "【\($0)】" } ?? "") + option.label).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 420, alignment: .leading)
            if let option = options.first(where: { $0.id == chosen[purpose] }) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let badge = option.badge { PurposeBadge(text: badge) }
                    if let note = option.note { Text(note).font(.harness(.caption2)).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
