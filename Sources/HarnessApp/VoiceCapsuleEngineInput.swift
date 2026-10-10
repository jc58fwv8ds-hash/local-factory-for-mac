import Foundation
import HarnessCore

struct VoiceCapsuleEngineInput: Equatable, Sendable {
    let manifest: VoiceCapsuleManifest
    let referenceAudio: Data
    let referenceTranscript: String?
    let capsuleRevisionHash: String
}
