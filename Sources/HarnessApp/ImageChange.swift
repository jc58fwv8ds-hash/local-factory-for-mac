import Foundation
import HarnessCore

/// One image asked for in the chat (2026-10-09): the instruction becomes an English prompt (the "large" role model), the
/// language models leave memory, and the image model chosen for 画像を作る runs. The picture is saved on this Mac.
@MainActor
@Observable
final class ImageChange: Identifiable {
    enum Status: Equatable { case running(String), ready(URL), failed(String), stopped }
    /// Image and video jobs run one at a time, in the order asked (2026-11-04: a second request beside a running one looked
    /// stuck on 「言葉にしています」 because its writer was waiting for the model memory).
    static var lastInQueue: Task<Void, Never>?
    var task: Task<Void, Never>?
    var isRunning: Bool { if case .running = status { true } else { false } }
    let id: UUID
    let instruction: String
    var status: Status = .running("準備しています")
    /// For the remaining time: what the time is filed under once the model is known, and when the job began.
    var jobKind: String?
    var startedAt = Date()
    /// Where the output will be, once the model runs: its script may write how far it has got beside it.
    var output: URL?
    var prompt: String?
    /// A video's character: the attached picture (a generated image attached again), which becomes its first frame.
    var referenceImage: Data?
    /// More attached pictures for a video: keyframes after the first (2026-11-10).
    var keyframeImages: [Data] = []
    var face: (project: UUID, attached: Data?)?   // the conversation's first face, and a newly attached one (2026-11-10)
    /// A picture attached to an image request: its person is described to the prompt writer (2026-11-07: an attached person
    /// was ignored and the prompt said only "a person").
    var personPicture: Data?
    /// The lines as a voice file made elsewhere (a copy, removed once done): the mouth moves to it.
    var voiceFile: URL?
    /// What the video says (2026-11-10): lines as the request asks, none, or the user's own script read by one voice each.
    var speech: VideoSpeech = .auto
    var script = ""
    /// The seed it was made with; a follow-up that changes this output uses it again.
    var seed = Int.random(in: 1...999_999)
    /// A video request (2026-10-19): the same flow with the 動画を作る model, saved as .mp4.
    let isVideo: Bool
    var purpose: ModelPurpose { isVideo ? .video : .image }

    init(id: UUID, instruction: String, isVideo: Bool = false) {
        self.id = id
        self.instruction = instruction
        self.isVideo = isVideo
    }
}
