import AppKit
import SwiftUI

/// The daily AI research news (2026-11-02): when it is made and uploaded, and what happened lately.
struct DailyNewsView: View {
    @State private var isConfirmingStop = false
    /// The log is for when something went wrong.
    private var showsLog: Bool { store.progress.map { $0.state == "failed" || $0.isStopped() } ?? false }
    @State private var store = DailyNewsStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("毎日のニュース").font(.harness(.title2, weight: .bold))
                }
                GroupBox("制作") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("毎日作る", isOn: $store.settings.enabled)
                        LabeledContent("作り始める時刻") { timeField($store.settings.productionTime) }
                        Stepper("紹介する論文 \(store.settings.papers) 本(1 本あたり 10 分ほど)", value: $store.settings.papers, in: 4...12)
                    }.padding(6)
                }
                GroupBox("YouTube") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("YouTube に上げる", isOn: $store.settings.youtube)
                        Picker("上げる時", selection: $store.settings.uploadAfterProduction) {
                            Text("完成したらすぐ").tag(true)
                            Text("決めた時刻").tag(false)
                        }.pickerStyle(.segmented).disabled(!store.settings.youtube)
                        if !store.settings.uploadAfterProduction {
                            LabeledContent("上げる時刻") { timeField($store.settings.uploadTime) }.disabled(!store.settings.youtube)
                        }
                        Text("非公開でアップロードします。公開は YouTube Studio で行ってください。")
                            .font(.harness(.caption)).foregroundStyle(.secondary)
                        HStack {
                            Label(store.youtubeAuthorized ? "許可済み" : (store.clientSecretPresent ? "未許可" : "OAuth クライアントの準備が必要"),
                                  systemImage: store.youtubeAuthorized ? "checkmark.seal" : "exclamationmark.triangle")
                                .foregroundStyle(store.youtubeAuthorized ? .green : .orange)
                            Spacer()
                            Button("YouTube を許可…") { store.authorizeYouTube() }.disabled(!store.clientSecretPresent)
                            Button("鍵の置き場所を開く") { store.openKeysFolder() }
                        }
                    }.padding(6)
                }
                HStack {
                    Button("保存して予約") { store.apply(); store.refresh() }.keyboardShortcut(.defaultAction)
                    Button("今すぐ作る") { store.produceNow() }
                    Button("動画のフォルダ") { store.openMoviesFolder() }
                    Spacer()
                    Button("更新") { store.refresh() }
                }
                if !store.message.isEmpty { Text(store.message).font(.harness(.body)) }
                if let progress = store.progress { progressCard(progress) }
                if !store.videos.isEmpty {
                    GroupBox("作った動画") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.videos, id: \.date) { item in videoRow(item.date, url: item.url) }
                            if !store.youtubeAuthorized {
                                Text("上げるには、上の「YouTube を許可…」を先に押してください。").font(.harness(.caption)).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                if showsLog {
                GroupBox("ログ(最後の12行)") {
                    Text(store.log.isEmpty ? "まだありません" : store.log)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        // The bar and the log follow the job while this screen is open.
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(5)); store.refresh() } }
    }

    /// One finished day: its link on YouTube, or a button that uploads it now, whatever the setting was when it was made.
    @ViewBuilder
    private func videoRow(_ date: String, url: String?) -> some View {
        HStack {
            Text(date).monospacedDigit()
            if let url, let link = URL(string: url) {
                Link(url, destination: link)
            } else if store.uploading == date {
                ProgressView().controlSize(.small)
                Text(store.uploadProgress).font(.harness(.caption)).foregroundStyle(.secondary)
                Button("止める", systemImage: "stop.fill") { store.stopUpload() }.controlSize(.small)
            } else {
                Button("YouTube に上げる(非公開)") { store.upload(date: date) }
                    .disabled(store.uploading != nil || !store.youtubeAuthorized)
            }
        }
    }

    private func progressCard(_ progress: DailyNewsProgress) -> some View {
        GroupBox("いまの作業") {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(max(progress.fraction, 0), 1))
                    .tint(progress.isStopped() ? .orange : .accentColor)
                HStack {
                    Text(progress.isStopped() && progress.state == "running" ? "止まりました(\(progress.stage)の途中)。「今すぐ作る」で続きから作ります" : progress.stage)
                        .font(.harness(.subheadline, weight: .medium))
                    Spacer()
                    Text("\(Int(progress.fraction * 100))%").monospacedDigit()
                    if progress.isRunning() {
                        Button("止める", systemImage: "stop.fill") { isConfirmingStop = true }.controlSize(.small)
                            .confirmationDialog("今日の動画づくりを止めますか?", isPresented: $isConfirmingStop) {
                                Button("止める", role: .destructive) { store.stopProduction() }
                            } message: { Text("途中までの作業は続きから使えない場合があります。") }
                    }
                }
                if !progress.detail.isEmpty { Text(progress.detail).font(.harness(.caption)).foregroundStyle(.secondary) }
                if progress.isRunning(), let left = progress.remaining(now: Date().timeIntervalSince1970) {
                    Text("残り およそ \(left)").font(.harness(.caption)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private func timeField(_ text: Binding<String>) -> some View {
        TextField("05:30", text: text).frame(width: 80).monospacedDigit()
            .foregroundStyle(DailyNewsSchedule.time(text.wrappedValue) == nil ? .red : .primary)
    }
}
