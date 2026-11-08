import AppKit
import AVKit
import HarnessCore
import SwiftUI

/// The card under an image request: progress, the finished picture (saved on this Mac), or why it failed.
struct ImageChangeCard: View {
    let change: ImageChange
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: change.isVideo ? "film" : "photo.artframe")
                Text(change.isVideo ? "動画" : "画像").font(.harness(.subheadline, weight: .semibold))
                Spacer()
                if let prompt = change.prompt, prompt != change.instruction {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).help(prompt)
                }
                if change.isRunning { Button("止める", systemImage: "stop.fill", action: stop).controlSize(.small) }
            }
            switch change.status {
            case .running(let step):
                JobProgress(step: step, kind: change.jobKind, startedAt: change.startedAt, output: change.output)
            case .stopped:
                Text("止めました。").font(.harness(.caption)).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.harness(.caption)).foregroundStyle(.secondary)
            case .ready:
                EmptyView()
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

/// A running job, updated every second (2026-11-08, the user: show progress as a bar or a turning mark). A bar of the
/// script's own steps when it reports them; else a bar of the time so far against the usual time, which stops short of the
/// end and says so when the job runs longer; else a turning mark with the time so far.
private struct JobProgress: View {
    let step: String
    let kind: String?
    let startedAt: Date
    let output: URL?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let reported = output.flatMap(GenerationProgress.read(for:))
            let expected = kind.flatMap { JobTimeEstimates().expected($0) }
            VStack(alignment: .leading, spacing: 6) {
                if let reported {
                    ProgressView(value: reported.fraction)
                    Text("\(reported.label)(\(reported.step)/\(reported.of))・経過 \(JobTimeEstimates.duration(elapsed))")
                } else if let expected {
                    ProgressView(value: min(elapsed / expected, 0.95))
                    Text(step + "・" + (elapsed < expected ? "残り およそ \(JobTimeEstimates.duration(expected - elapsed))"
                                        : "いつもより長くかかっています(経過 \(JobTimeEstimates.duration(elapsed)))"))
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(step + "・経過 \(JobTimeEstimates.duration(elapsed))")
                    }
                }
            }
            .font(.harness(.caption)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// A finished picture or video inside the conversation, from the note's path, so it is there after the app restarts too.
struct GeneratedMediaView: View {
    let url: URL
    @State private var showsSteps = false

    private var steps: [URL] { GeneratedMedia.steps(of: url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !GeneratedMedia.exists(url) {
                Text("ファイルが見つかりません: \(url.lastPathComponent)").font(.harness(.caption)).foregroundStyle(.secondary)
            } else {
                if url.pathExtension == "mp4" {
                    VideoPreview(url: url).frame(height: 360).clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 8) {
                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("開く") { NSWorkspace.shared.open(url) }
                    if let recipe = WorkspaceStore.savedRecipe(for: url) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary).help(recipe.prompt)
                    }
                    if !steps.isEmpty { Toggle("途中", isOn: $showsSteps).toggleStyle(.button) }
                }
                .controlSize(.small)
                if showsSteps { StepsRow(steps: steps) }
            }
        }
    }
}

/// The steps a picture went through, side by side, each with its name (1-着替え, 2-はだけ, …).
private struct StepsRow: View {
    let steps: [URL]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(steps, id: \.self) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        Group {
                            if step.pathExtension == "mp4" {
                                VideoPreview(url: step).frame(width: 140, height: 200)
                            } else if let image = NSImage(contentsOf: step) {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 140, height: 200)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { NSWorkspace.shared.open(step) }
                        Text(step.deletingPathExtension().lastPathComponent).font(.harness(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// The player, from AppKit (2026-11-05): SwiftUI's VideoPlayer aborted the whole app the moment a finished video was shown
/// (getSuperclassMetadata inside _AVKit_SwiftUI on macOS 27.2).
struct VideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause() }
}
