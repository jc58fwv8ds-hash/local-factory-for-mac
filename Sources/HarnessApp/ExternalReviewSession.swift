import Foundation
import HarnessCore
import Observation

@MainActor
@Observable
final class ExternalReviewSession {
    let project: HarnessProject
    let rootPath: String
    let report: ProjectValidationReport
    let analysis: BuildFailureAnalysis?
    var packet: ExternalReviewPacket?
    var importedResponse = ""
    var isPreparing = false
    var handoffMessage: String?
    var preparationWarning: String?

    @ObservationIgnored private let sourceProvider: any ProjectSourceContextProviding
    @ObservationIgnored private let handoff: any ExternalReviewHandoffProviding

    init(
        project: HarnessProject,
        rootPath: String,
        report: ProjectValidationReport,
        analysis: BuildFailureAnalysis?,
        sourceProvider: any ProjectSourceContextProviding,
        handoff: any ExternalReviewHandoffProviding
    ) {
        self.project = project
        self.rootPath = rootPath
        self.report = report
        self.analysis = analysis
        self.sourceProvider = sourceProvider
        self.handoff = handoff
    }

    var canImport: Bool {
        !importedResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func prepare() async {
        guard packet == nil, !isPreparing else { return }
        isPreparing = true
        let sourceContext: SourceContextSnapshot?
        do {
            sourceContext = try await sourceProvider.collect(
                path: rootPath,
                budget: .compact
            )
        } catch is CancellationError {
            isPreparing = false
            return
        } catch {
            sourceContext = nil
            preparationWarning = "ソースを含められませんでした。検査結果だけでレビュー包を作成しました：\(error.localizedDescription)"
        }
        packet = ExternalReviewPacketBuilder.make(
            project: project,
            rootPath: rootPath,
            report: report,
            analysis: analysis,
            sourceContext: sourceContext
        )
        isPreparing = false
    }

    func copyReviewRequest() {
        guard let packet else { return }
        handoff.copy(packet.content)
        handoffMessage = "レビュー依頼文をクリップボードへコピーしました。"
    }

    func copyAndOpenChatGPT() {
        guard let packet else { return }
        handoff.copy(packet.content)
        handoffMessage = handoff.openChatGPT()
            ? "依頼文をコピーし、通常ChatGPTを開きました。チャット欄へ貼り付けて送信してください。"
            : "依頼文はコピーしましたが、ChatGPTを開けませんでした。ブラウザでchatgpt.comを開いてください。"
    }
}
