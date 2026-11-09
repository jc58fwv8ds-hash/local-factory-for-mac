import AppKit
import AVFoundation
import HarnessCore
import SwiftUI
import UniformTypeIdentifiers

/// 学習: the material for teaching a model something new (2026-11-08). Sets on the left, named for what they teach; the
/// chosen set's pictures and videos on the right. Drop pictures, videos or whole folders anywhere on it, or pick them.
struct TrainingView: View {
    @State private var sets: [TrainingMaterials.Set] = []
    @State private var chosen: String?
    @State private var newName = ""
    @State private var isTargeted = false
    @State private var message: String?

    private let materials = TrainingMaterials.standard

    private var current: TrainingMaterials.Set? { sets.first { $0.name == chosen } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("学習").font(.harness(.title3, weight: .semibold))
                List(selection: $chosen) {
                    ForEach(sets) { set in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(set.name)
                            Text("画像 \(set.pictures)・動画 \(set.videos)").font(.harness(.caption)).foregroundStyle(.secondary)
                        }
                        .tag(set.name)
                        .contextMenu { Button("ゴミ箱に入れる", role: .destructive) { removeSet(set.name) } }
                    }
                }
                .listStyle(.sidebar)
                HStack {
                    TextField("覚えさせたいもの(例:浴衣)", text: $newName).onSubmit(addSet)
                    Button("追加", action: addSet).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 240)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if let current {
                    HStack {
                        Text(current.name).font(.harness(.title3, weight: .semibold))
                        Spacer()
                        Button("ファイルを選ぶ", systemImage: "plus", action: pick)
                    }
                    if current.files.isEmpty {
                        dropHint
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                                ForEach(current.files, id: \.self) { file in MaterialTile(file: file) { remove(file) } }
                            }
                        }
                    }
                } else {
                    dropHint
                }
                if let message { Text(message).font(.harness(.caption)).foregroundStyle(.secondary) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: drop)
        }
        .onAppear(perform: reload)
    }

    private var dropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square").font(.harness(.title)).foregroundStyle(.secondary)
            Text(sets.isEmpty || current == nil ? "左で名前を付けて追加し、画像や動画、フォルダをここにドラッグします。"
                 : "画像や動画、フォルダをここにドラッグします。")
                .foregroundStyle(.secondary)
            if current != nil { Button("ファイルを選ぶ", action: pick) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        sets = materials.sets()
        if chosen == nil || !sets.contains(where: { $0.name == chosen }) { chosen = sets.first?.name }
    }

    private func addSet() {
        guard let name = try? materials.addSet(named: newName) else { return }
        newName = ""
        reload()
        chosen = name
    }

    private func removeSet(_ name: String) {
        try? materials.removeSet(name)
        reload()
    }

    private func remove(_ file: URL) {
        try? materials.remove(file)
        reload()
    }

    private func add(_ urls: [URL]) {
        var target = chosen
        if target == nil { target = try? materials.addSet(named: urls.first?.deletingPathExtension().lastPathComponent ?? "") }
        guard let target else { return }
        let added = (try? materials.add(urls, to: target)) ?? 0
        message = added == 0 ? "画像か動画が見つかりませんでした。" : "\(added) 件を入れました。"
        reload()
        chosen = target
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .movie, .folder]
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let collected = URLBox()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { add(collected.urls) }
        return true
    }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    func append(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
}

/// One picture or video: its picture (a video's first frame), its name, and × to put it in the Trash.
private struct MaterialTile: View {
    let file: URL
    let remove: () -> Void
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image { Image(nsImage: image).resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
                }
                .frame(width: 120, height: 120).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    if TrainingMaterials.videoTypes.contains(file.pathExtension.lowercased()) {
                        Image(systemName: "play.fill").padding(6).foregroundStyle(.white).shadow(radius: 2)
                    }
                }
                Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.harness(.title3)) }
                    .buttonStyle(.plain).padding(4).help("ゴミ箱に入れる")
            }
            Text(file.lastPathComponent).font(.harness(.caption)).lineLimit(1).truncationMode(.middle).frame(width: 120)
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(file) }
        .task(id: file) { image = await Self.thumbnail(file) }
    }

    static func thumbnail(_ file: URL) async -> NSImage? {
        if TrainingMaterials.videoTypes.contains(file.pathExtension.lowercased()) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            guard let frame = try? await generator.image(at: .zero).image else { return nil }
            return NSImage(cgImage: frame, size: .zero)
        }
        return NSImage(contentsOf: file)
    }
}
