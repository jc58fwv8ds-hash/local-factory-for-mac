import HarnessExecution
import SwiftUI

struct ValidationRecoveryNotice: View {
    let status: ValidationRecoveryStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("前回の検証記録", systemImage: "clock.arrow.circlepath")
                .font(.harness(.subheadline, weight: .semibold))
            Text(status.explanation)
                .font(.harness(.caption))
            if status == .unresolved {
                Text("別の検証が動いていないことを確認してから、再検証してください。")
                    .font(.harness(.caption))
            }
            Text("これは保存済み記録の照合です。新しいビルドやテストは実行していません。")
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
