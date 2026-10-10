import HarnessCore

extension WorkspaceStore {
    func beginVoiceInput() {
        voiceCapture.press()
    }

    func endVoiceInput() {
        voiceCapture.release()
    }

    func cancelVoiceInput() {
        voiceCapture.cancel()
    }

    func dismissVoiceStatus() {
        voiceCapture.dismissStatus()
    }

    func toggleVoiceConversation() {
        if voiceConversation.isActive {
            if voiceConversation.phase == .speaking {
                voiceConversation.interruptSpokenResponse()
                return
            }
            voiceConversation.stop()
            return
        }
        guard hasSelectedProject else {
            presentNotice("先に会話するプロジェクトを選んでね", kind: .information)
            return
        }
        guard hasConfiguredModel else {
            presentNotice("先に会話に使うAIモデルを選んでね", kind: .information)
            return
        }
        guard allowInteraction(.startVoiceConversation) else { return }
        voiceConversation.start()
    }

    func dismissVoiceConversationStatus() {
        voiceConversation.dismissStatus()
    }

    func insertVoiceDraft(_ transcript: VoiceTranscript) {
        let decision = VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .command,
            gesture: .none,
            action: .insertComposerDraft
        )
        guard decision.isAuthorized else {
            presentNotice(decision.reason, kind: .information)
            return
        }
        instruction = VoiceDraftComposition.inserting(transcript, into: instruction)
    }

    func acceptVoiceConversationTurn(
        _ transcript: VoiceTranscript
    ) -> VoiceConversationSubmissionResult {
        let authority = VoiceActionAuthorityPolicy.decision(
            transcript: transcript,
            intent: .discussion,
            gesture: .userActivatedConversationMode,
            action: .submitConversation
        )
        guard authority.isAuthorized else {
            return .paused(message: authority.reason)
        }
        guard let projectID = library.selectedProjectID else {
            return .paused(message: "会話するプロジェクトを選んでね")
        }
        let decision = acceptInstruction(
            transcript.text,
            origin: .user,
            images: [],
            deliveryMode: .voice
        )
        switch decision.status {
        case .accepted:
            return .accepted(projectID: projectID)
        case .queued, .busy, .rejected, .unavailable:
            return .paused(message: decision.message)
        }
    }
}
