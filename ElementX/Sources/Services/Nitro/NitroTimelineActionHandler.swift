//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import UniformTypeIdentifiers

final class NitroTimelineActionHandler {
    private let roomProxy: JoinedRoomProxyProtocol
    private let timelineController: TimelineControllerProtocol
    private let userSession: UserSessionProtocol
    private let voiceMessageRecorder: VoiceMessageRecorderProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let appSettings: AppSettings
    private let transcriptionService: NitroTranscriptionServiceProtocol
    private let reminderService: NitroReminderServiceProtocol
    private let sendAction: @MainActor (TimelineInteractionHandlerAction) -> Void
    private let didFinishCurrentVoiceMessage: @MainActor () -> Void
    
    private var reminderTask: Task<Void, Never>?
    private var reminderTaskID: UUID?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionTaskID: UUID?
    
    init(roomProxy: JoinedRoomProxyProtocol,
         timelineController: TimelineControllerProtocol,
         userSession: UserSessionProtocol,
         voiceMessageRecorder: VoiceMessageRecorderProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         appSettings: AppSettings,
         transcriptionService: NitroTranscriptionServiceProtocol,
         reminderService: NitroReminderServiceProtocol,
         sendAction: @escaping @MainActor (TimelineInteractionHandlerAction) -> Void,
         didFinishCurrentVoiceMessage: @escaping @MainActor () -> Void) {
        self.roomProxy = roomProxy
        self.timelineController = timelineController
        self.userSession = userSession
        self.voiceMessageRecorder = voiceMessageRecorder
        self.userIndicatorController = userIndicatorController
        self.appSettings = appSettings
        self.transcriptionService = transcriptionService
        self.reminderService = reminderService
        self.sendAction = sendAction
        self.didFinishCurrentVoiceMessage = didFinishCurrentVoiceMessage
    }
    
    func presentReminderCreate(for item: EventBasedTimelineItemProtocol) {
        guard let eventID = item.id.eventID else {
            sendAction(.displayErrorToast(UntranslatedL10n.errorReminderRequestFailedIos))
            return
        }
        
        reminderTask?.cancel()
        let taskID = UUID()
        reminderTaskID = taskID
        reminderTask = Task { [weak self] in
            guard let self else { return }
            defer { finishReminderTask(taskID: taskID) }
            
            let threadRootID: String?
            if let activeThreadRootID = timelineController.timelineKind.threadRootEventID {
                threadRootID = activeThreadRootID
            } else if case let .success(event) = await roomProxy.loadOrFetchEventDetails(for: eventID) {
                threadRootID = event.threadRootEventId()
            } else {
                threadRootID = nil
            }
            guard !Task.isCancelled else { return }
            
            let viewModel = NitroReminderCreateScreenViewModel(eventID: eventID,
                                                               threadRootID: threadRootID,
                                                               roomProxy: roomProxy,
                                                               clientProxy: userSession.clientProxy,
                                                               reminderService: reminderService,
                                                               userIndicatorController: userIndicatorController)
            sendAction(.showNitroReminderCreate(viewModel))
        }
    }
    
    func transcribeCurrentVoiceMessage() {
        guard canStartAudioTranscription else {
            sendAction(.requestNitroAudioTranscriptionConsent(.currentVoiceMessage))
            return
        }
        
        startCurrentVoiceMessageTranscription()
    }
    
    func confirmAudioTranscription(_ request: NitroAudioTranscriptionRequest) {
        appSettings.hasAcknowledgedAudioTranscriptionWarning = true
        
        switch request {
        case .currentVoiceMessage:
            startCurrentVoiceMessageTranscription()
        case .timeline(let itemID, let sendToThread):
            startTimelineAudioTranscription(itemID: itemID, sendToThread: sendToThread)
        }
    }
    
    func transcribeTimelineAudio(itemID: TimelineItemIdentifier, sendToThread: Bool) {
        guard canStartAudioTranscription else {
            sendAction(.requestNitroAudioTranscriptionConsent(.timeline(itemID: itemID, sendToThread: sendToThread)))
            return
        }
        
        startTimelineAudioTranscription(itemID: itemID, sendToThread: sendToThread)
    }
    
    func sendTranscriptToThread(_ info: NitroTranscriptInfo) async {
        guard await sendTranscriptToThread(info.text, replyingTo: info.itemID) else {
            sendAction(.displayErrorToast(UntranslatedL10n.errorAudioTranscriptionFailedIos))
            return
        }
    }
    
    func cancelAll() {
        reminderTaskID = nil
        reminderTask?.cancel()
        reminderTask = nil
        transcriptionTaskID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }
    
    private func startCurrentVoiceMessageTranscription() {
        startTranscription { [weak self] in
            await self?.performTranscribeCurrentVoiceMessage()
        }
    }
    
    private func performTranscribeCurrentVoiceMessage() async {
        guard !Task.isCancelled else { return }
        guard let audioPlayerState = voiceMessageRecorder.previewAudioPlayerState,
              let recordingURL = voiceMessageRecorder.recordingURL else {
            sendAction(.displayErrorToast(UntranslatedL10n.errorAudioTranscriptionFailedIos))
            return
        }
        
        sendAction(.composer(action: .setMode(mode: .previewVoiceMessage(state: audioPlayerState,
                                                                         waveform: .url(recordingURL),
                                                                         isUploading: true))))
        await voiceMessageRecorder.stopPlayback()
        guard !Task.isCancelled else { return }
        
        switch await transcribeAudioFile(at: recordingURL,
                                         filename: recordingURL.lastPathComponent,
                                         contentType: "audio/mp4") {
        case .success(let transcript):
            guard !Task.isCancelled else { return }
            sendAction(.composer(action: .setMode(mode: .default)))
            sendAction(.composer(action: .setText(plainText: transcript, htmlText: nil)))
            sendAction(.composer(action: .setFocus))
            didFinishCurrentVoiceMessage()
            await voiceMessageRecorder.deleteRecording()
        case .failure(let error):
            guard !Task.isCancelled, error != .cancelled else { return }
            sendAction(.composer(action: .setMode(mode: .previewVoiceMessage(state: audioPlayerState,
                                                                             waveform: .url(recordingURL),
                                                                             isUploading: false))))
            sendAction(.displayErrorToast(UntranslatedL10n.errorAudioTranscriptionFailedIos))
        }
    }
    
    private func startTimelineAudioTranscription(itemID: TimelineItemIdentifier, sendToThread: Bool) {
        startTranscription { [weak self] in
            await self?.performTranscribeTimelineAudio(itemID: itemID, sendToThread: sendToThread)
        }
    }
    
    // swiftlint:disable:next cyclomatic_complexity
    private func performTranscribeTimelineAudio(itemID: TimelineItemIdentifier, sendToThread: Bool) async {
        guard !Task.isCancelled else { return }
        guard let item = timelineController.timelineItems.firstUsingStableID(itemID) as? EventBasedMessageTimelineItemProtocol,
              let content = audioContent(from: item),
              let source = content.source else {
            sendAction(.displayErrorToast(UntranslatedL10n.errorAudioTranscriptionFailedIos))
            return
        }
        
        let indicatorID = UUID().uuidString
        userIndicatorController.submitIndicator(.init(id: indicatorID,
                                                      type: .modal,
                                                      title: UntranslatedL10n.commonTranscribingAudioIos,
                                                      persistent: true))
        defer {
            userIndicatorController.retractIndicatorWithId(indicatorID)
        }
        
        guard case let .success(fileHandle) = await userSession.mediaProvider.loadFileFromSource(source, filename: content.filename),
              let fileURL = fileHandle.url else {
            guard !Task.isCancelled else { return }
            sendAction(.displayErrorToast(UntranslatedL10n.errorAudioTranscriptionFailedIos))
            return
        }
        guard !Task.isCancelled else { return }
        
        let result = await transcribeAudioFile(at: fileURL,
                                               filename: content.filename,
                                               contentType: content.contentType?.preferredMIMEType ?? "application/octet-stream")
        guard !Task.isCancelled else { return }
        guard case let .success(transcript) = result else {
            guard result != .failure(.cancelled) else { return }
            sendAction(.displayErrorToast(UntranslatedL10n.errorAudioTranscriptionFailedIos))
            return
        }
        
        if sendToThread {
            guard await sendTranscriptToThread(transcript, replyingTo: itemID) else {
                guard !Task.isCancelled else { return }
                sendAction(.displayErrorToast(UntranslatedL10n.errorAudioTranscriptionFailedIos))
                return
            }
        } else {
            guard !Task.isCancelled else { return }
            sendAction(.showNitroTranscript(.init(itemID: itemID, text: transcript)))
        }
    }
    
    private func transcribeAudioFile(at fileURL: URL,
                                     filename: String,
                                     contentType: String) async -> Result<String, NitroTranscriptionError> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard let homeserverURL = URL(string: userSession.clientProxy.homeserver),
              case let .success(openIDToken) = await userSession.clientProxy.requestOpenIDToken() else {
            if Task.isCancelled {
                return .failure(.cancelled)
            }
            return .failure(.invalidResponse)
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        
        return await transcriptionService.transcribeAudio(at: fileURL,
                                                          filename: filename,
                                                          contentType: contentType,
                                                          homeserverURL: homeserverURL,
                                                          openIDToken: openIDToken)
    }
    
    private func startTranscription(_ operation: @escaping @MainActor () async -> Void) {
        guard transcriptionTask == nil else { return }
        
        let taskID = UUID()
        transcriptionTaskID = taskID
        transcriptionTask = Task { [weak self] in
            guard !Task.isCancelled else {
                self?.finishTranscription(taskID: taskID)
                return
            }
            await operation()
            self?.finishTranscription(taskID: taskID)
        }
    }
    
    private var canStartAudioTranscription: Bool {
        !roomProxy.infoPublisher.value.isEncrypted || appSettings.hasAcknowledgedAudioTranscriptionWarning
    }
    
    private func finishReminderTask(taskID: UUID) {
        guard reminderTaskID == taskID else { return }
        reminderTaskID = nil
        reminderTask = nil
    }
    
    private func finishTranscription(taskID: UUID) {
        guard transcriptionTaskID == taskID else { return }
        transcriptionTaskID = nil
        transcriptionTask = nil
    }
    
    private func sendTranscriptToThread(_ transcript: String, replyingTo itemID: TimelineItemIdentifier) async -> Bool {
        guard let eventID = itemID.eventID else { return false }
        
        let rootEventID: String
        if let activeThreadRootEventID = timelineController.timelineKind.threadRootEventID {
            rootEventID = activeThreadRootEventID
        } else if case let .success(event) = await roomProxy.loadOrFetchEventDetails(for: eventID) {
            rootEventID = event.threadRootEventId() ?? eventID
        } else {
            return false
        }
        
        guard case let .success(threadTimeline) = await roomProxy.threadTimeline(eventID: rootEventID) else {
            return false
        }
        
        let plainText = "Transcript:\n\(transcript)"
        let html = "<strong>Transcript</strong><br />\(escapedHTML(transcript).replacingOccurrences(of: "\n", with: "<br />"))"
        switch await threadTimeline.sendMessage(plainText,
                                                html: html,
                                                inReplyToEventID: eventID,
                                                intentionalMentions: .empty) {
        case .success:
            return true
        case .failure:
            return false
        }
    }
    
    private func audioContent(from item: EventBasedMessageTimelineItemProtocol) -> AudioRoomTimelineItemContent? {
        switch item.contentType {
        case .audio(let content), .voice(let content):
            content
        default:
            nil
        }
    }
    
    private func escapedHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
