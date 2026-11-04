import Foundation
import HarnessCore
import Observation

/// The stages of the latest model call or media job, for the line above the message field.
@MainActor
@Observable
final class InferenceIndicator {
    static let shared = InferenceIndicator()
    var stages = InferenceStages()
    var isActive: Bool { stages.current != nil }

    func begin(_ stage: InferenceStages.Stage) {
        stages = InferenceStages()
        stages.enter(stage)
    }
    func enter(_ stage: InferenceStages.Stage) { stages.enter(stage) }
    func piece() { stages.piece() }
    func finish() { stages.finish() }
}
