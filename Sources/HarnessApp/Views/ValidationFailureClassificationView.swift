import HarnessCore
import SwiftUI

struct ValidationFailureClassificationView: View {
    let assessment: ValidationFailureAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(assessment.title, systemImage: symbol)
                .font(.harness(.caption, weight: .semibold))
                .foregroundStyle(color)
            Text(assessment.nextAction)
                .font(.harness(.caption2))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !assessment.permitsCodeChanges {
                Text("環境を再確認するまでは、AIのコード修正と制作計画の変更を開始しません。")
                    .font(.harness(.caption2, weight: .medium))
                    .foregroundStyle(color)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.2)))
    }

    private var color: Color {
        assessment.permitsCodeChanges ? .blue : .orange
    }

    private var symbol: String {
        assessment.permitsCodeChanges
            ? "wrench.and.screwdriver.fill"
            : "desktopcomputer.trianglebadge.exclamationmark"
    }
}
