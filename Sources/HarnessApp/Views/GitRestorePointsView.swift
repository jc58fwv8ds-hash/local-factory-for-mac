import HarnessCore
import SwiftUI

struct GitRestorePointsView: View {
    @Environment(\.dismiss) private var dismiss
    let checkpoints: [GitFileCheckpoint]
    let provider: any GitCheckpointing
    let onRestored: (GitFileCheckpoint) -> Void
    @State private var pendingCheckpoint: GitFileCheckpoint?
    @State private var restoringCheckpointID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.harness(.caption))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(checkpoints) { checkpoint in
                        checkpointRow(checkpoint)
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .confirmationDialog(
            "この復元ポイントへ戻しますか？",
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            Button("内容を確認して復元") {
                guard let checkpoint = pendingCheckpoint else { return }
                Task { await restore(checkpoint) }
            }
            Button("キャンセル", role: .cancel) { pendingCheckpoint = nil }
        } message: {
            if let checkpoint = pendingCheckpoint {
                Text("現在の内容が保存直後と一致する場合だけ、\(checkpoint.relativePath)を元へ戻します。")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.harness(.title2))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Git復元ポイント")
                    .font(.harness(.headline))
                Text("Local Factoryが保存前に保持したファイル内容です。")
                    .font(.harness(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("完了") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func checkpointRow(_ checkpoint: GitFileCheckpoint) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.harness(.title3))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(checkpoint.relativePath)
                    .font(.harness(.subheadline, weight: .semibold).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(checkpoint.createdAt, style: .relative)
                    Text(checkpoint.shortObjectID)
                        .monospaced()
                }
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if restoringCheckpointID == checkpoint.id {
                ProgressView().controlSize(.small)
            } else {
                Button("復元") { pendingCheckpoint = checkpoint }
                    .buttonStyle(.bordered)
                    .disabled(restoringCheckpointID != nil)
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary))
    }

    private func restore(_ checkpoint: GitFileCheckpoint) async {
        pendingCheckpoint = nil
        restoringCheckpointID = checkpoint.id
        errorMessage = nil
        do {
            _ = try await provider.restore(checkpoint)
            await provider.discard(checkpoint)
            onRestored(checkpoint)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        restoringCheckpointID = nil
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingCheckpoint != nil },
            set: { if !$0 { pendingCheckpoint = nil } }
        )
    }
}
