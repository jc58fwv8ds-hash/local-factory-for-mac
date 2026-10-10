import Darwin
import Foundation
import TaskOrchestrator
import HarnessCore
import HarnessExecution
import HarnessKernel
import HarnessKernelContracts
import HarnessKernelPersistence

/// Explicit, bounded real-model smoke run; never invoked by swift test.
@main
struct HarnessKernelPilot {
  static let target = "Sources/MemoryStore/MemoryStore.swift"
  static let request = """
    メモを書いたら保存して、アプリを開き直しても残るようにしてね。
    日本語や絵文字、空のメモもそのまま残して。保存し直したら新しい内容に置き換えてね。
    初めて使う時は空でいいけど、保存データが壊れていたら黙って消さずにエラーで知らせてほしい。
    """

  static func main() async {
    do { try await run() }
    catch {
      let detail = (error as? DevicePreparationError)?.errorDescription ?? String(describing: error)
      let message = "Pilot stopped: \(detail)\n"
      try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
      exit(1)
    }
  }

  static func run() async throws {
    var arguments = CommandLine.arguments
    if arguments.dropFirst().first == "--local-verifier-experiment" {
      try await LocalVerifierExperiment.run(arguments)
      return
    }
    if arguments.dropFirst().first == "--isolated-package-host", arguments.count == 7 {
      let candidate = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
      let root = URL(fileURLWithPath: arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
      guard let operation = IsolatedPackageExecution.Operation(rawValue: arguments[5]) else { throw IsolatedPackageExecution.Failure.invalidScope }
      let adapter = IsolatedPackageExecution(candidate: candidate, root: root, taskID: root.lastPathComponent,
        protectedPaths: ["Package.swift"], stable: URL(fileURLWithPath: arguments[6]))
      _ = try await GeneratedCodeExecutionGate.executePackage(adapter, operation: operation, evidence: URL(fileURLWithPath: arguments[4]))
      return
    }
    if arguments.dropFirst().first == "--execution-supervisor", arguments.count == 3 {
      try await ExecutionSupervisor.serve(directory: URL(fileURLWithPath: arguments[2]))
      return
    }
    if arguments.dropFirst().first == "--isolated-validate-resume" {
      try await IsolatedValidationResume.run(arguments)
      return
    }
    if arguments.dropFirst().first == "--batch-recover" {
      try await BatchRecoveryCommand.run(arguments)
      return
    }
    if arguments.dropFirst().first == "--verifier-phase6-case" {
      try await VerifierPhase6Command.run(arguments)
      return
    }
    if arguments.dropFirst().first == "--verifier-phase5-case" {
      try await VerifierPhase5Command.run(arguments)
      return
    }
    if arguments.dropFirst().first == "--verifier-phase4-case" {
      try await VerifierPhase4Command.run(arguments)
      return
    }
    if arguments.dropFirst().first == "--verifier-phase3-case" {
      try await VerifierPhase3Command.run(arguments)
      return
    }
    if arguments.dropFirst().first == "--verifier-arms" {
      try VerifierArmsCommand.run(arguments)
      return
    }
    if arguments.dropFirst().first == "--verifier-admit" {
      try VerifierAdmissionCommand.run(arguments)
      return
    }
    if arguments.dropFirst().first == "--requirement-verify" {
      try await BatchRequirementFinalizeCommand.finalize(arguments: arguments)
      return
    }
    if arguments.dropFirst().first == "--inference-health-baseline" {
      try await InferenceHealthGate.establishBaseline(arguments: arguments)
      return
    }
    if arguments.dropFirst().first?.hasPrefix("--suite-") == true {
      try await SuiteCommand.run(arguments)
      return
    }
    if arguments.dropFirst().first == "--canary-batch-resume" {
      try await BatchCanaryRunner.resume(arguments: arguments)
      return
    }
    if arguments.dropFirst().first == "--canary-batch" {
      try await BatchCanaryRunner.run(arguments: arguments)
      return
    }
    if arguments.dropFirst().first == "--canary-bootstrap" {
      try await CanaryBootstrapExporter.run(arguments: arguments)
      return
    }
    if arguments.dropFirst().first == "--canary-small-package" {
      try await SmallCanaryRunner.run(arguments: arguments)
      return
    }
    if arguments.dropFirst().first == "--canary-local-status" {
      try await DogfoodLocalStatusCommand.run(arguments: arguments)
      return
    }
    if arguments.dropFirst().first == "--shadow-task" {
      try DogfoodShadowProbe.run(arguments: arguments)
      return
    }
    if arguments.dropFirst().first == "--canary-personal-memory-deterministic" {
      try await DogfoodCanaryRunner.run(arguments: arguments)
      return
    }
    if arguments.dropFirst().first == "--canary-watch-status" {
      try await DogfoodCanaryWatchRunner.run(arguments: arguments)
      return
    }
    if arguments.dropFirst().first == "--check-package" {
      try await ProjectTaskVerification.check(arguments: arguments)
      return
    }
    if arguments.dropFirst().first == "--inspect-device" {
      try await DevicePreparationProbe.run(arguments: arguments)
      return
    }
    if ["--edit-project", "--edit-checked-package"].contains(arguments.dropFirst().first ?? "") {
      try await ProjectTaskRunner.run(arguments: arguments)
      return
    }
    let disableFixtureSandbox = arguments.last == "--disable-swiftpm-sandbox"
    if disableFixtureSandbox { arguments.removeLast() }
    if arguments.dropFirst().first == "--review-case" {
      try await PilotReviewCalibration.run(arguments: arguments)
      return
    }
    if arguments.dropFirst().first == "--review-existing" {
      try await PilotReviewProbe.run(arguments: arguments)
      return
    }
    var reviewModel: String?
    if arguments.count >= 3, arguments[arguments.count - 2] == "--review-model" {
      reviewModel = arguments.last
      arguments.removeLast(2)
    }
    guard arguments.count == 4 || arguments.count == 7 else {
      print(
        "Usage: HarnessKernelPilot <fixture-directory> <new-output-directory> <installed-ollama-model> OR --replay-source <swift-file> --scenario <success|limit|interrupted|reviewRepair|reviewLimit> [--disable-swiftpm-sandbox]"
      )
      return
    }
    let responseSource = try PilotResponseSource(arguments: arguments)
    // The opt-in only controls nested SwiftPM for trusted offline fixtures, not the host sandbox.
    guard !disableFixtureSandbox || responseSource.scenario != nil,
      !(responseSource.isReviewScenario && reviewModel != nil)
    else { throw PilotError.incompatibleOptions }
    let fixture = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
    let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw PilotError.outputExists
    }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let source = output.appendingPathComponent("source")
    try FileManager.default.copyItem(at: fixture, to: source)
    let contract = try await RepairAcceptanceContract.capture(root: source,
      paths: ["Package.swift", "Tests/MemoryStoreTests/MemoryStoreTests.swift"])
    let contractEncoder = JSONEncoder()
    contractEncoder.outputFormatting = [.sortedKeys]
    try contractEncoder.encode(contract).write(to: output.appendingPathComponent("acceptance-contract.json"), options: .atomic)
    let validator = RecordedProjectValidationService(
      provider: LocalProjectValidationService(disableSwiftPMSandbox: disableFixtureSandbox), directory: output.appendingPathComponent("runs"),
      requireTests: true
    )
    let startedAt = Date()
    let baseline = try await validator.validate(rootPath: source.path)
    guard !baseline.succeeded else { throw PilotError.fixtureAlreadyPasses }
    guard baseline.checks.contains(where: { $0.kind == .build && $0.succeeded }),
      baseline.checks.contains(where: { $0.kind == .test && !$0.succeeded && $0.duration > 0 })
    else { throw PilotError.baselineUnavailable }
    var attempts: [PilotAttempt] = []
    var instruction = request
    var reviewFeedback: RepairReviewFeedback?
    let editStep = KernelStep(instruction: "指定された保存処理の1ファイルを編集し、固定テストで検証する")
    let acceptance = VerificationRequirement(
      criterion: "固定された保存・復元テストとビルドが成功する", kind: .testExecution)
    let engine = try KernelEngine(
      runID: UUID(),
      journal: FileKernelJournal(
        directory: output.appendingPathComponent("repair-events")
      ))
    try await engine.record(
      .planned(
        KernelPlan(
          userRequest: request, modelIdentifier: responseSource.modelIdentifier,
          steps: [editStep], requirements: [acceptance])))
    do {
      for number in 1...2 {
        try await reviewFeedback?.verifySource(root: source)
        let attemptID = UUID()
        try await engine.record(.stepStarted(stepID: editStep.id, attemptID: attemptID))
        let generationStart = Date()
        let editor = ProjectFileEditor()
        let document = try await editor.load(rootPath: source.path, relativePath: target)
        let inferenceRequest = InferenceRequest(
          runtime: .ollama, modelIdentifier: responseSource.modelIdentifier,
          messages: try FileEditPromptBuilder.messages(
            document: document, instruction: instruction, reviewFeedback: reviewFeedback?.explanation),
          maximumOutputTokens: InferenceOutputBudget.fileChange, structuredOutput: .fileContent
        )
        let response: String
        if let replay = try responseSource.response(attempt: number, current: document.content, messages: inferenceRequest.messages) {
          try JSONEncoder().encode(inferenceRequest.messages).write(
            to: output.appendingPathComponent("builder-input-\(number).json"), options: .atomic)
          response = replay
        } else { response = try await collect(inferenceRequest) }
        let content = try FileEditResponseParser.proposedContent(from: response)
        let proposal = try await editor.makeProposal(document: document, proposedContent: content)
        // Only this source file can be submitted by the model; tests/manifests remain fixed.
        try Data(document.content.utf8).write(
          to: output.appendingPathComponent("checkpoint-\(number).swift"), options: .atomic)
        try await engine.record(
          .decisionRecorded("編集前の内容をcheckpoint-\(number).swiftへ保存。変更対象は\(target)のみ。"))
        try await editor.apply(rootPath: source.path, proposal: proposal)
        if responseSource.scenario == .interrupted { throw CancellationError() }
        let generationSeconds = Date().timeIntervalSince(generationStart)
        let report = try await validator.validate(rootPath: source.path)
        guard let validationRun = await validator.lastRunDirectory else {
          throw PilotError.missingEvidence
        }
        try await engine.record(
          .decisionRecorded("検証結果: runs/\(validationRun.lastPathComponent)。合格: \(report.succeeded)")
        )
        // A model assertion or a report Boolean alone cannot complete the parent run.
        var reference: String?
        var stoppedReview: RepairReview?
        reviewFeedback = nil
        if report.succeeded {
          let receipt = try await RepairAcceptanceEvaluator().evaluate(
            contract: contract, root: source, validationRun: validationRun)
          reference = "runs/\(validationRun.lastPathComponent)/\(receipt)"
          let reviewer: (any RepairReviewing)? = responseSource.isReviewScenario
            ? PilotReviewFixture(attempt: number, alwaysReject: responseSource.scenario == .reviewLimit)
            : reviewModel.map { LocalRepairReviewer(model: $0) }
          if let reviewer {
            let outcome = try await PilotReviewDecision.evaluate(contract: contract, source: source,
              validationRun: validationRun, reviewer: reviewer, output: output, attempt: number)
            switch outcome {
            case .accepted: break
            case .repair(let feedback): reviewFeedback = feedback; reference = nil
            case .stop(let review): stoppedReview = review; reference = nil
            }
            try await engine.record(.decisionRecorded("別のコード評価: review-\(number).json、評価元: \(reviewModel ?? "scripted-fixture")。修正提案: \(reviewFeedback != nil)"))
          }
          try await engine.record(.decisionRecorded("独立した固定条件チェックで、テスト・設定の不変と検証証拠を確認しました。LLMによる品質評価ではありません。"))
        } else {
          reference = nil
        }
        let state = try await engine.record(
          .stepFinished(attemptID: attemptID, succeeded: reference != nil))
        attempts.append(
          PilotAttempt(
            number: number, generationSeconds: generationSeconds,
            passed: reference != nil, runDirectory: await validator.lastRunDirectory?.path))
        let result = PilotResult(
          request: request, model: responseSource.modelIdentifier, baselinePassed: baseline.succeeded,
          attempts: attempts, wallClockSeconds: Date().timeIntervalSince(startedAt))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(
          to: output.appendingPathComponent("pilot.json"), options: .atomic)
        print(
          "Attempt \(number): \(reference != nil ? "passed" : "failed"); evidence saved to \(output.path)"
        )
        // A completed rejection is a known failure, not an interrupted tool operation.
        if let stoppedReview { throw RepairReviewError.notAccepted(stoppedReview) }
        if let reference {
          try await engine.record(
            .verificationRecorded(
              KernelEvidence(
                requirementID: acceptance.id,
                revision: state.revision, passed: true, reportReference: reference)))
          try await engine.record(.completed)
          return
        }
        let failure = report.checks.filter { !$0.succeeded }.map(\.output).joined(separator: "\n")
        instruction = reviewFeedback == nil ? request + "\n検証で次の問題が出たので直してね。\n" + String(failure.suffix(12_000)) : request
        try await engine.record(.decisionRecorded("検証の失敗または参考評価を、残っている修正枠へ渡す。新しい制作記録は作成しない。"))
      }
      try await engine.record(.paused(reason: "この試作は2回まで。修正方針を確認するため停止しました。"))
      throw PilotError.repairLimit
    } catch {
      if case RepairReviewError.notAccepted(let review) = error {
        try JSONEncoder().encode(review).write(to: output.appendingPathComponent("review-rejected.json"), options: .atomic)
        try await engine.record(.decisionRecorded("評価が完了を許可しませんでした。review-rejected.jsonを確認してください。"))
      }
      let state = await engine.snapshot()
      if state.phase == .ready || state.phase == .executing {
        try await engine.record(.paused(reason: "制作が中断しました。編集と検証の結果を確認してから再開してください。"))
      }
      throw error
    }
  }

  static func collect(_ request: InferenceRequest) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        var result = ""
        for try await delta in await LocalInferenceService().events(for: request) {
          try Task.checkCancellation()
          result += delta
          guard result.utf8.count <= 96_000 else { throw PilotError.responseTooLarge }
        }
        return result
      }
      group.addTask {
        try await Task.sleep(for: .seconds(120))
        throw PilotError.timeout
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw PilotError.timeout }
      return result
    }
  }
}

private enum PilotError: Error {
  case outputExists, fixtureAlreadyPasses, baselineUnavailable, repairLimit, responseTooLarge, timeout, missingEvidence, incompatibleOptions
}
private struct PilotAttempt: Encodable {
  let number: Int
  let generationSeconds: Double
  let passed: Bool
  let runDirectory: String?
}
private struct PilotResult: Encodable {
  let request: String
  let model: String
  let baselinePassed: Bool
  let attempts: [PilotAttempt]
  let wallClockSeconds: Double
}
