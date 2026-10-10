import HarnessCore
import SwiftUI

struct CreationLoopCard: View {
    @Bindable var store: WorkspaceStore

    private var readiness: CreationCompletionReadiness {
        CreationCompletionPolicy.readiness(for: store.project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("制作ループ", systemImage: "arrow.triangle.2.circlepath")
                .font(.harness(.subheadline, weight: .semibold))

            Picker(
                "方式",
                selection: Binding(
                    get: { store.project.creationLoop.reviewMode },
                    set: { store.setCreationLoopReviewMode($0) }
                )
            ) {
                ForEach(CreationLoopReviewMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier(HarnessAccessibilityID.creationLoopMode)

            Text(store.project.creationLoop.reviewMode.detail)
                .font(.harness(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.project.creationLoop.phase.displayName)
                        .font(.harness(.caption, weight: .semibold))
                    Text("制作サイクル \(store.project.creationLoop.iteration)回")
                        .font(.harness(.caption2).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if CreationCompletionPolicy.canOfferCompletion(
                    for: store.project.creationLoop.phase
                ) {
                    Button("完成として終了") { store.completeCreationLoop() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!readiness.isReady)
                        .accessibilityIdentifier(HarnessAccessibilityID.creationLoopComplete)
                }
            }

            if CreationCompletionPolicy.canOfferCompletion(
                for: store.project.creationLoop.phase
            ), let guidance = readiness.guidance {
                Label(guidance, systemImage: "checklist")
                    .font(.harness(.caption))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .inspectorCard()
    }
}
