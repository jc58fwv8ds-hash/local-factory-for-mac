import HarnessCore
import SwiftUI

struct ProjectFormFields: View {
    @Binding var draft: ProjectDraft
    let showsStage: Bool

    var body: some View {
        Form {
            TextField("プロジェクト名", text: $draft.name)
                .accessibilityIdentifier(HarnessAccessibilityID.projectFormName)
            TextField("どんなものを作りますか？", text: $draft.summary, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityIdentifier(HarnessAccessibilityID.projectFormSummary)

            Section("対象") {
                HStack(spacing: 10) {
                    ForEach(TargetPlatform.allCases) { target in
                        TargetPlatformButton(
                            target: target,
                            isSelected: draft.targets.contains(target)
                        ) {
                            toggle(target)
                        }
                    }
                }
            }

            if showsStage {
                Picker("制作ステージ", selection: $draft.stage) {
                    ForEach(ProjectStage.allCases) { stage in
                        Text(stage.rawValue).tag(stage)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func toggle(_ target: TargetPlatform) {
        if let index = draft.targets.firstIndex(of: target) {
            draft.targets.remove(at: index)
        } else {
            draft.targets.append(target)
        }
    }
}

private struct TargetPlatformButton: View {
    let target: TargetPlatform
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                Text(target.rawValue)
            }
            .font(.harness(.caption, weight: .medium))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
    }
}
