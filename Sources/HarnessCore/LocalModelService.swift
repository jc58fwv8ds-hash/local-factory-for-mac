import Foundation

private struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String
    let didTimeOut: Bool
}

public actor LocalModelService {
    private let runtimes: [RuntimeCandidate]

    public init(runtimes: [RuntimeCandidate]) {
        self.runtimes = runtimes
    }

    public func inventory() -> ModelInventory {
        var models: [InstalledModel] = []
        var reports: [RuntimeReport] = []

        for runtime in runtimes {
            guard runtime.isInstalled else {
                reports.append(
                    RuntimeReport(
                        runtime: runtime,
                        availability: .notInstalled,
                        detail: runtime.kind == .harness ? "内蔵ランタイムは次の段階で追加します" : "未インストール"
                    )
                )
                continue
            }

            switch runtime.kind {
            case .harness:
                reports.append(RuntimeReport(runtime: runtime, availability: .ready, detail: "利用できます"))
            case .ollama:
                let result = run(runtime: runtime, arguments: ["list"], timeout: 8)
                if result.didTimeOut {
                    reports.append(RuntimeReport(runtime: runtime, availability: .timedOut, detail: "応答がありません"))
                } else if result.exitCode == 0 {
                    let discovered = ModelOutputParser.parseOllamaList(result.output)
                    models.append(contentsOf: discovered.compactMap { model in
                        let details = run(
                            runtime: runtime,
                            arguments: ["show", model.identifier],
                            timeout: 5
                        )
                        guard details.exitCode == 0 else { return model }
                        let capabilities = ModelCapabilityParser.ollamaVisualCapabilities(
                            details.output
                        )
                        guard capabilities.contains(.textConversation) else { return nil }
                        return model.withCapabilities(capabilities)
                    })
                    reports.append(RuntimeReport(runtime: runtime, availability: .ready, detail: "利用できます"))
                } else {
                    reports.append(RuntimeReport(runtime: runtime, availability: .installedButStopped, detail: "Ollamaを起動してください"))
                }
            case .backburner:
                // Fixed model from the Backburner install; the App starts the server the first time it is used.
                let model = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Models/Qwen3.8-27B-IQ4_XS.gguf").path
                if FileManager.default.fileExists(atPath: model) {
                    models.append(InstalledModel(identifier: "qwen3.8-27b-iq4xs", displayName: "Qwen3.8-27B (Backburner 高速)",
                                                 sizeLabel: "15.5 GB", runtime: .backburner, localPath: model,
                                                 capabilities: [.textConversation]))
                    reports.append(RuntimeReport(runtime: runtime, availability: .ready, detail: "使うときに自動で起動します"))
                } else {
                    reports.append(RuntimeReport(runtime: runtime, availability: .failed, detail: "モデルファイルが見つかりません"))
                }
            case .lmStudio:
                let result = run(runtime: runtime, arguments: ["ls", "--json"], timeout: 20)
                if result.didTimeOut {
                    reports.append(RuntimeReport(runtime: runtime, availability: .timedOut, detail: "LM Studioの起動を待っています"))
                } else if result.exitCode == 0 {
                    models.append(contentsOf: ModelOutputParser.parseLMStudioJSON(result.output))
                    reports.append(RuntimeReport(runtime: runtime, availability: .ready, detail: "利用できます"))
                } else {
                    reports.append(
                        RuntimeReport(
                            runtime: runtime,
                            availability: .failed,
                            detail: ModelCommandFailureExplainer.runtimeMessage(
                                from: result.output,
                                runtime: runtime.kind
                            )
                        )
                    )
                }
            }
        }

        return ModelInventory(models: models, runtimes: reports)
    }

    public func install(
        _ request: ModelAcquisitionRequest,
        onProgress: @escaping @Sendable (ModelAcquisitionProgress) async -> Void = { _ in }
    ) async throws {
        let runtimeKind = request.runtime
        guard let runtime = runtimes.first(where: { $0.kind == runtimeKind && $0.isInstalled }) else {
            throw ModelManagementError.runtimeUnavailable(runtimeKind)
        }
        let arguments: [String]
        switch runtimeKind {
        case .harness:
            throw ModelManagementError.unsupportedOperation("内蔵AIランタイムはまだ準備中です。")
        case .ollama:
            arguments = ["pull", request.modelIdentifier]
        case .lmStudio:
            arguments = ["get", request.modelIdentifier, "--gguf", "--yes"]
        case .backburner:
            throw ModelManagementError.unsupportedOperation("Backburner は導入済みのモデルだけを使います。")
        }

        let runner = BoundedCommandRunner(
            timeout: .seconds(21_600),
            maximumOutputBytes: 20_000
        )
        let result: BoundedCommandResult
        let progressStream = ModelAcquisitionProgressStream()
        do {
            result = try await runner.run(
                executableURL: URL(fileURLWithPath: runtime.executablePath),
                arguments: arguments,
                onOutput: { output in
                    for progress in await progressStream.append(output) {
                        await onProgress(progress)
                    }
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch BoundedCommandError.unavailable {
            throw ModelManagementError.runtimeUnavailable(runtimeKind)
        } catch BoundedCommandError.timedOut {
            throw ModelManagementError.timedOut(arguments.joined(separator: " "))
        }
        if let progress = await progressStream.finish() { await onProgress(progress) }
        guard result.exitCode == 0 else {
            throw ModelManagementError.commandFailed(
                ModelCommandFailureExplainer.installationMessage(
                    from: result.output,
                    runtime: runtimeKind
                )
            )
        }
    }

    public func remove(_ model: InstalledModel) throws {
        guard model.runtime == .ollama else {
            throw ModelManagementError.unsupportedOperation(
                "LM Studioモデルの削除は、共有ファイルを誤って消さないようLM Studio側で行ってください。"
            )
        }
        guard let runtime = runtimes.first(where: { $0.kind == .ollama && $0.isInstalled }) else {
            throw ModelManagementError.runtimeUnavailable(.ollama)
        }

        let result = run(runtime: runtime, arguments: ["rm", model.identifier], timeout: 120)
        guard !result.didTimeOut else {
            throw ModelManagementError.timedOut("ollama rm")
        }
        guard result.exitCode == 0 else {
            throw ModelManagementError.commandFailed(
                "Ollamaからモデルを削除できませんでした。Ollamaの状態を確認してください。"
            )
        }
    }

    private func run(
        runtime: RuntimeCandidate,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.executablePath)
        process.arguments = arguments

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-model-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        do {
            let handle = try FileHandle(forWritingTo: outputURL)
            process.standardOutput = handle
            process.standardError = handle
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            let didTimeOut = process.isRunning
            if didTimeOut {
                process.terminate()
                process.waitUntilExit()
            }
            try? handle.close()

            let data = (try? Data(contentsOf: outputURL)) ?? Data()
            try? FileManager.default.removeItem(at: outputURL)
            return CommandResult(
                exitCode: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self),
                didTimeOut: didTimeOut
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            return CommandResult(exitCode: -1, output: error.localizedDescription, didTimeOut: false)
        }
    }

}
