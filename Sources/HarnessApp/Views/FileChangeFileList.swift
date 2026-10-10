import HarnessCore
import SwiftUI

struct FileChangeFileList: View {
    @Bindable var session: FileChangeSession
    let onEditingTarget: () -> Void
    let onBeginArtifactPlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("編集可能なファイル")
                .font(.harness(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            Button {
                onEditingTarget()
                session.beginNewFile()
            } label: {
                Label("新規ファイルを追加", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .disabled(session.isBusy || session.isApplied || session.artifactPlan != nil)
            .accessibilityIdentifier(HarnessAccessibilityID.sourceNewFile)

            Button(action: onBeginArtifactPlan) {
                Label("複数ファイル計画", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .disabled(session.isBusy || session.isApplied || session.artifactPlan != nil)
            .accessibilityIdentifier(HarnessAccessibilityID.sourceArtifactPlan)

            if session.isLoading && session.files.isEmpty {
                Spacer()
                ProgressView("ファイルを確認中…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if session.files.isEmpty {
                ContentUnavailableView(
                    "編集可能なファイルなし",
                    systemImage: "doc.slash",
                    description: Text("UTF-8のソースまたは設定ファイルを確認してください。")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(session.files) { file in
                            fileButton(file)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Label("最大500ファイル・各512KB", systemImage: "shield.lefthalf.filled")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
                .padding(12)
        }
        .background(.secondary.opacity(0.035))
    }

    private func fileButton(_ file: EditableSourceFile) -> some View {
        Button {
            onEditingTarget()
            Task { await session.select(file.relativePath) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "doc.text")
                    .foregroundStyle(
                        !session.isCreatingNewFile && session.selectedPath == file.relativePath
                            ? Color.accentColor
                            : .secondary
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.relativePath)
                        .font(.harness(.caption).monospaced())
                        .lineLimit(2)
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(file.byteCount),
                        countStyle: .file
                    ))
                    .font(.harness(.caption2))
                    .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(8)
            .background(
                !session.isCreatingNewFile && session.selectedPath == file.relativePath
                    ? Color.accentColor.opacity(0.1)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.isBusy || session.isApplied || session.artifactPlan != nil)
    }
}
