import Foundation

public enum RunCoordinatorWorkflow {
    public static func beginNext(
        in project: inout HarnessProject,
        now: Date = .now
    ) -> RunCoordinatorDecision {
        if let blocker = activeBlocker(in: project) {
            return .stopped(blocker)
        }
        if project.runCoordinator.cycleCountSinceConfirmation
            >= project.runCoordinator.maximumCycles {
            pause(.iterationLimit, in: &project, now: now)
            return .stopped(.iterationLimit)
        }
        guard let index = nextWorkItemIndex(in: project) else {
            project.runCoordinator.phase = .readyForFinalValidation
            project.runCoordinator.currentWorkItemID = nil
            project.runCoordinator.stopReason = nil
            project.runCoordinator.updatedAt = now
            return .readyForFinalValidation
        }

        project.workItems[index].status = .active
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        project.runCoordinator.attemptedCycleCount += 1
        project.runCoordinator.cycleCountSinceConfirmation += 1
        project.runCoordinator.currentWorkItemID = project.workItems[index].id
        project.runCoordinator.phase = .awaitingChange
        project.runCoordinator.stopReason = nil
        project.runCoordinator.updatedAt = now
        append(.selected, workItemID: project.workItems[index].id, in: &project, now: now)
        project.currentActivity = "\(project.workItems[index].title)を1項目ずつ進めます"
        return .selected(selection(for: project.workItems[index]))
    }

    public static func resumeCurrent(
        in project: inout HarnessProject,
        now: Date = .now
    ) -> RunCoordinatorDecision {
        guard project.operationCheckpoint == nil,
              project.computerOperationCheckpoint == nil else {
            return .stopped(.operationInProgress)
        }
        if project.runCoordinator.phase == .paused,
           project.runCoordinator.stopReason == .iterationLimit,
           project.runCoordinator.currentWorkItemID == nil {
            project.runCoordinator.cycleCountSinceConfirmation = 0
            project.runCoordinator.phase = .readyForNextItem
            project.runCoordinator.stopReason = nil
            project.runCoordinator.updatedAt = now
            return beginNext(in: &project, now: now)
        }
        if project.runCoordinator.phase == .blocked,
           project.runCoordinator.stopReason == .workItemUnavailable {
            project.runCoordinator.currentWorkItemID = nil
            project.runCoordinator.phase = .readyForNextItem
            project.runCoordinator.stopReason = nil
            project.runCoordinator.updatedAt = now
            return beginNext(in: &project, now: now)
        }
        guard let item = currentWorkItem(in: project), item.status != .completed else {
            reconcileWorkPlan(in: &project, now: now)
            return .stopped(.workItemUnavailable)
        }
        project.runCoordinator.phase = project.runCoordinator.lastFailureFingerprint == nil
            ? .awaitingChange
            : .awaitingRepair
        project.runCoordinator.stopReason = nil
        project.runCoordinator.updatedAt = now
        return .selected(selection(for: item))
    }

    public static func recordedChange(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        guard let id = project.runCoordinator.currentWorkItemID,
              project.runCoordinator.phase != .inactive,
              project.runCoordinator.phase != .readyForNextItem,
              project.runCoordinator.phase != .readyForFinalValidation else { return }
        project.runCoordinator.phase = .awaitingValidation
        project.runCoordinator.stopReason = nil
        project.runCoordinator.updatedAt = now
        append(.changeApplied, workItemID: id, in: &project, now: now)
    }

    public static func observedSourceChange(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        guard let id = project.runCoordinator.currentWorkItemID,
              project.runCoordinator.phase != .inactive,
              project.runCoordinator.phase != .readyForNextItem,
              project.runCoordinator.phase != .readyForFinalValidation else { return }
        project.runCoordinator.phase = .awaitingValidation
        project.runCoordinator.stopReason = nil
        project.runCoordinator.updatedAt = now
        append(.sourceChanged, workItemID: id, in: &project, now: now)
    }

    public static func recordedValidation(
        _ report: ProjectValidationReport,
        analysis: BuildFailureAnalysis? = nil,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        guard let id = project.runCoordinator.currentWorkItemID,
              project.runCoordinator.phase == .awaitingValidation
                || project.runCoordinator.phase == .awaitingRepair else { return }
        if report.succeeded {
            project.runCoordinator.phase = .awaitingReview
            project.runCoordinator.consecutiveMatchingFailures = 0
            project.runCoordinator.lastFailureFingerprint = nil
            project.runCoordinator.stopReason = nil
            append(.validationSucceeded, workItemID: id, in: &project, now: now)
        } else {
            let assessment = ValidationFailureClassifier.classify(
                report: report,
                analysis: analysis
            )
            let fingerprint = failureFingerprint(for: report)
            if fingerprint == project.runCoordinator.lastFailureFingerprint {
                project.runCoordinator.consecutiveMatchingFailures += 1
            } else {
                project.runCoordinator.consecutiveMatchingFailures = 1
            }
            project.runCoordinator.lastFailureFingerprint = fingerprint
            append(.validationFailed, workItemID: id, in: &project, now: now)
            if !assessment.permitsCodeChanges {
                project.runCoordinator.phase = .awaitingValidation
                project.runCoordinator.stopReason = nil
            } else if project.runCoordinator.consecutiveMatchingFailures >= 2 {
                project.runCoordinator.phase = .blocked
                project.runCoordinator.stopReason = .repeatedFailure
                append(.blocked, workItemID: id, in: &project, now: now)
            } else {
                project.runCoordinator.phase = .awaitingRepair
            }
        }
        project.runCoordinator.updatedAt = now
    }

    @discardableResult
    public static func approveCurrent(
        in project: inout HarnessProject,
        now: Date = .now
    ) -> Bool {
        guard project.runCoordinator.phase == .awaitingReview,
              let id = project.runCoordinator.currentWorkItemID,
              let index = project.workItems.firstIndex(where: { $0.id == id }) else {
            return false
        }
        project.workItems[index].status = .completed
        CreationCompletionPolicy.invalidateValidationEvidence(in: &project)
        project.runCoordinator.approvedCycleCount += 1
        project.runCoordinator.currentWorkItemID = nil
        project.runCoordinator.consecutiveMatchingFailures = 0
        project.runCoordinator.lastFailureFingerprint = nil
        project.runCoordinator.stopReason = nil
        append(.approved, workItemID: id, in: &project, now: now)
        project.runCoordinator.phase = nextWorkItemIndex(in: project) == nil
            ? .readyForFinalValidation
            : .readyForNextItem
        project.runCoordinator.updatedAt = now
        project.currentActivity = "1項目を確認済みにしました"
        return true
    }

    public static func pause(
        _ reason: RunCoordinatorStopReason = .userRequested,
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        guard let id = project.runCoordinator.currentWorkItemID else {
            project.runCoordinator.phase = .paused
            project.runCoordinator.stopReason = reason
            project.runCoordinator.updatedAt = now
            return
        }
        project.runCoordinator.phase = .paused
        project.runCoordinator.stopReason = reason
        project.runCoordinator.updatedAt = now
        append(.paused, workItemID: id, in: &project, now: now)
    }

    public static func reconcileWorkPlan(
        in project: inout HarnessProject,
        now: Date = .now
    ) {
        guard let id = project.runCoordinator.currentWorkItemID else { return }
        guard let item = project.workItems.first(where: { $0.id == id }),
              item.responseToMessageID == nil else {
            project.runCoordinator.phase = .blocked
            project.runCoordinator.stopReason = .workItemUnavailable
            project.runCoordinator.updatedAt = now
            return
        }
        if item.status == .completed {
            project.runCoordinator.currentWorkItemID = nil
            project.runCoordinator.phase = nextWorkItemIndex(in: project) == nil
                ? .readyForFinalValidation
                : .readyForNextItem
            project.runCoordinator.updatedAt = now
        }
    }

    public static func failureFingerprint(for report: ProjectValidationReport) -> String {
        report.checks.filter { !$0.succeeded }.map {
            let normalizedOutput = $0.output.replacingOccurrences(of: "\r\n", with: "\n")
            return "\($0.kind.rawValue):\($0.exitCode):\(stableDigest(normalizedOutput))"
        }.joined(separator: ",")
    }

    private static func stableDigest(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func activeBlocker(in project: HarnessProject) -> RunCoordinatorBlocker? {
        if project.operationCheckpoint != nil || project.computerOperationCheckpoint != nil {
            return .operationInProgress
        }
        switch project.runCoordinator.phase {
        case .awaitingChange, .awaitingRepair, .paused:
            return project.runCoordinator.currentWorkItemID == nil
                ? nil : .operationInProgress
        case .awaitingValidation: return .validationRequired
        case .awaitingReview: return .reviewRequired
        case .blocked where project.runCoordinator.stopReason == .repeatedFailure:
            return .repeatedFailure
        case .blocked: return .workItemUnavailable
        default: return nil
        }
    }

    static func nextWorkItemIndex(in project: HarnessProject) -> Int? {
        let candidates = ProjectInstructionContext.productionCandidates(in: project)
            .filter { $0.status != .completed }
        let next = candidates.first { $0.status == .active }
            ?? candidates.first { $0.status == .needsAttention }
            ?? candidates.first { $0.status == .pending }
        return next.flatMap { item in project.workItems.firstIndex { $0.id == item.id } }
    }

    static func currentWorkItem(in project: HarnessProject) -> WorkItem? {
        guard let id = project.runCoordinator.currentWorkItemID else { return nil }
        return project.workItems.first { $0.id == id && $0.responseToMessageID == nil }
    }

    private static func selection(for item: WorkItem) -> RunCoordinatorWorkSelection {
        let detail = item.detail.isEmpty ? "この項目の完了条件を確認して実装する" : item.detail
        return RunCoordinatorWorkSelection(
            id: item.id,
            title: item.title,
            instruction: "\(item.title)\n\(detail)"
        )
    }

    private static func append(
        _ event: RunCoordinatorEvent,
        workItemID: UUID,
        in project: inout HarnessProject,
        now: Date
    ) {
        let nextSequence = (project.runCoordinator.records.last?.sequence ?? 0) + 1
        project.runCoordinator.records.append(
            RunCoordinatorRecord(
                sequence: nextSequence,
                workItemID: workItemID,
                event: event,
                occurredAt: now
            )
        )
        if project.runCoordinator.records.count > RunCoordinatorState.maximumRecords {
            project.runCoordinator.records.removeFirst(
                project.runCoordinator.records.count - RunCoordinatorState.maximumRecords
            )
        }
    }
}
