import SwiftUI

struct SafetyRow: View {
    let title: String
    let isAutomatic: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isAutomatic
                ? "checkmark.circle.fill"
                : "person.crop.circle.badge.questionmark")
                .foregroundStyle(isAutomatic ? .green : .orange)
            Text(title)
                .font(.harness(.caption))
            Spacer()
            Text(isAutomatic ? "自動" : "要承認")
                .font(.harness(.caption2, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    func inspectorCard() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.78),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}
