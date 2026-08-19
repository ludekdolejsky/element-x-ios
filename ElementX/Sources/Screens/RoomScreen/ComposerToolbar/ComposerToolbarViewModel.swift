//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import GameKit
import MatrixRustSDK
import SwiftUI
import WysiwygComposer

typealias ComposerToolbarViewModelType = StateStoreViewModel<ComposerToolbarViewState, ComposerToolbarViewAction>

final class ComposerToolbarViewModel: ComposerToolbarViewModelType, ComposerToolbarViewModelProtocol {
    private var initialText: String?
    private let wysiwygViewModel: WysiwygComposerViewModel
    private let completionSuggestionService: CompletionSuggestionServiceProtocol
    private let roomProxy: JoinedRoomProxyProtocol
    private let analyticsService: AnalyticsServiceProtocol
    private let draftService: ComposerDraftServiceProtocol
    private let emojiProvider: EmojiProviderProtocol?
    private let appSettings: AppSettings
    private var identityPinningViolations = [String: RoomMemberProxyProtocol]()
    private var preservedCustomEmojis = [CustomEmoji]()
    
    private let mentionBuilder: MentionBuilderProtocol
    private let attributedStringBuilder: AttributedStringBuilderProtocol
    
    private var hasAppeared = false
    
    private let actionsSubject: PassthroughSubject<ComposerToolbarViewModelAction, Never> = .init()
    var actions: AnyPublisher<ComposerToolbarViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    private struct WysiwygLinkData {
        let range: NSRange
        var url: String
        var text: String
    }
    
    private var currentLinkData: WysiwygLinkData?
    
    private var replyLoadingTask: Task<Void, Never>?
    private var sendMessageTask: Task<Void, Never>?
    
    init(initialText: String? = nil,
         roomProxy: JoinedRoomProxyProtocol,
         wysiwygViewModel: WysiwygComposerViewModel,
         completionSuggestionService: CompletionSuggestionServiceProtocol,
         mediaProvider: MediaProviderProtocol,
         mentionDisplayHelper: MentionDisplayHelper,
         appSettings: AppSettings,
         analyticsService: AnalyticsServiceProtocol,
         composerDraftService: ComposerDraftServiceProtocol,
         emojiProvider: EmojiProviderProtocol? = nil,
         nitroTasksEnabled: Bool = false) {
        self.initialText = initialText
        self.wysiwygViewModel = wysiwygViewModel
        self.completionSuggestionService = completionSuggestionService
        self.analyticsService = analyticsService
        self.roomProxy = roomProxy
        draftService = composerDraftService
        self.emojiProvider = emojiProvider
        self.appSettings = appSettings
        let roomInfo = roomProxy.infoPublisher.value
        
        mentionBuilder = MentionBuilder()
        attributedStringBuilder = AttributedStringBuilder(cacheKey: "Composer", mentionBuilder: mentionBuilder)
        
        super.init(initialViewState: ComposerToolbarViewState(wysiwygViewModel: wysiwygViewModel,
                                                              isRoomEncrypted: roomInfo.isEncrypted,
                                                              isLocationSharingEnabled: appSettings.mapTilerConfiguration.publisher.value.isEnabled,
                                                              canCreateNitroTask: Self.canCreateNitroTask(roomInfo: roomInfo,
                                                                                                          nitroTasksEnabled: nitroTasksEnabled),
                                                              bindings: .init()),
                   mediaProvider: mediaProvider)
        
        state.keyCommands = [
            .enter { [weak self] in
                self?.process(viewAction: .sendMessage)
            }
        ]
        
        roomProxy.infoPublisher
            .map(\.isEncrypted)
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .weakAssign(to: \.state.isRoomEncrypted, on: self)
            .store(in: &cancellables)
        
        setupNitroTaskCreationSubscription(nitroTasksEnabled: nitroTasksEnabled)

        context.$viewState
            .map(\.composerMode)
            .removeDuplicates()
            .sink { [weak self] in
                self?.wysiwygViewModel.shouldReplaceText = $0.isTextEditingEnabled
                self?.actionsSubject.send(.composerModeChanged(mode: $0))
            }
            .store(in: &cancellables)
        
        context.$viewState
            .map(\.bindings.composerFocused)
            .removeDuplicates()
            .sink { [weak self] in self?.actionsSubject.send(.composerFocusedChanged(isFocused: $0)) }
            .store(in: &cancellables)
        
        wysiwygViewModel.$isContentEmpty
            .removeDuplicates()
            .sink { [weak self] isEmpty in
                self?.state.composerEmpty = isEmpty
                self?.actionsSubject.send(.contentChanged(isEmpty: isEmpty))
            }
            .store(in: &cancellables)
        
        wysiwygViewModel.$attributedContent
            .sink { [weak self] content in
                self?.state.bindings.plainComposerText = NSAttributedString(string: content.text.string)
                self?.state.bindings.selectedRange = content.selection
            }
            .store(in: &cancellables)
        
        // Needs to be observable or the placeholder and the dictation state will not be managed correctly.
        wysiwygViewModel.objectWillChange
            .sink { [weak self] _ in
                self?.context.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        wysiwygViewModel.$actionStates
            .map { actions in
                FormatType
                    .allCases
                    .map { type in
                        FormatItem(type: type,
                                   state: actions[type.composerAction] ?? .disabled)
                    }
            }
            .weakAssign(to: \.state.bindings.formatItems, on: self)
            .store(in: &cancellables)
        
        wysiwygViewModel.$suggestionPattern
            .sink { [weak self] suggestionPattern in
                self?.completionSuggestionService.setSuggestionTrigger(suggestionPattern?.toElementPattern)
            }
            .store(in: &cancellables)
        
        completionSuggestionService.suggestionsPublisher
            .weakAssign(to: \.state.suggestions, on: self)
            .store(in: &cancellables)
        
        setupMentionsHandling(mentionDisplayHelper: mentionDisplayHelper)
        focusComposerIfHardwareKeyboardConnected()
        
        let identityStatusChangesPublisher = roomProxy.identityStatusChangesPublisher.receive(on: DispatchQueue.main)
        
        Task { [weak self] in
            for await changes in identityStatusChangesPublisher.values {
                guard !Task.isCancelled else {
                    return
                }
                
                await self?.processIdentityStatusChanges(changes)
            }
        }
        .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification).sink { [weak self] _ in
            self?.saveDraft()
        }
        .store(in: &cancellables)
    }
    
    private static func canCreateNitroTask(roomInfo: RoomInfoProxyProtocol, nitroTasksEnabled: Bool) -> Bool {
        guard nitroTasksEnabled,
              roomInfo.successor == nil,
              let powerLevels = roomInfo.powerLevels else {
            return false
        }
        return powerLevels.canOwnUser(sendMessage: .roomMessage) && powerLevels.canOwnUserPinOrUnpin()
    }

    private func setupNitroTaskCreationSubscription(nitroTasksEnabled: Bool) {
        roomProxy.infoPublisher
            .map { Self.canCreateNitroTask(roomInfo: $0, nitroTasksEnabled: nitroTasksEnabled) }
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .weakAssign(to: \.state.canCreateNitroTask, on: self)
            .store(in: &cancellables)
    }

    // MARK: - Public
    
    func start() {
        setupComposerIfNeeded()
        Task { await loadDraft() }
    }
    
    func stop() {
        sendMessageTask?.cancel()
        sendMessageTask = nil
        state.isResolvingCustomEmojis = false
        saveDraft()
    }
    
    func sendEmoji(_ emoji: EmojiPickerEmojiViewData) {
        guard state.canSendStandaloneEmoji else { return }
        
        if let customEmoji = emoji.customEmoji {
            let content = CustomEmojiMessageContent(emoji: customEmoji)
            sendMessage(plain: content.plain,
                        html: content.html,
                        mode: state.composerMode,
                        intentionalMentions: .empty,
                        customEmojis: [customEmoji])
        } else {
            actionsSubject.send(.sendMessage(plain: emoji.value,
                                             html: nil,
                                             mode: state.composerMode,
                                             intentionalMentions: .empty))
        }
    }
    
    override func process(viewAction: ComposerToolbarViewAction) {
        switch viewAction {
        case .composerAppeared:
            setupComposerIfNeeded()
        case .composerDisappeared:
            saveDraft()
        case .sendMessage:
            guard !state.sendButtonDisabled else { return }
            
            switch state.composerMode {
            case .previewVoiceMessage:
                actionsSubject.send(.voiceMessage(.send))
            case .recordVoiceMessage:
                MXLog.warning("Ignoring send action while recording a voice message.")
            default:
                sendMessageResolvingCustomEmojis(plain: wysiwygViewModel.content.markdown,
                                                 html: wysiwygViewModel.content.html,
                                                 mode: state.composerMode,
                                                 intentionalMentions: wysiwygViewModel.getMentionsState().toIntentionalMentions())
            }
        case .editLastMessage:
            actionsSubject.send(.editLastMessage)
        case .cancelReply:
            set(mode: .default)
        case .cancelEdit:
            if let draft = draftService.loadVolatileDraft() {
                handleLoadDraft(draft)
                draftService.clearVolatileDraft()
            } else {
                set(text: "")
                set(mode: .default)
            }
        case .attach(let attachment):
            state.bindings.composerFocused = false
            actionsSubject.send(.attach(attachment))
        case .handlePasteOrDrop(let providers):
            actionsSubject.send(.handlePasteOrDrop(providers: providers))
        case .pasteRichText(let content):
            pasteRichText(content)
        case .enableTextFormatting:
            state.bindings.composerFormattingEnabled = true
            state.bindings.composerFocused = true
            
            analyticsService.trackInteraction(name: .MobileRoomComposerFormattingEnabled)
        case .composerAction(let action):
            if action == .link {
                createLinkAlert()
            } else {
                wysiwygViewModel.apply(action)
            }
        case .selectedSuggestion(let suggestion):
            handleSuggestion(suggestion)
        case .voiceMessage(let voiceMessageAction):
            processVoiceMessageAction(voiceMessageAction)
        }
    }
    
    private func pasteRichText(_ content: NitroMessageCopyFormatter.RichPasteContent) {
        let selection = wysiwygViewModel.attributedContent.selection
        let textLength = wysiwygViewModel.attributedContent.text.length
        let replacesAll = selection.location == 0 && selection.length == textLength
        let appends = selection.location == textLength && selection.length == 0

        guard replacesAll || appends else {
            _ = wysiwygViewModel.replaceText(range: selection, replacementText: content.plainText)
            return
        }

        switch content {
        case .html(let html, _):
            wysiwygViewModel.setHtmlContent(replacesAll ? html : wysiwygViewModel.content.html + html)
        case .markdown(let markdown):
            wysiwygViewModel.setMarkdownContent(replacesAll ? markdown : wysiwygViewModel.content.markdown + markdown)
        }
    }

    func process(timelineAction: TimelineComposerAction) {
        switch timelineAction {
        case .setMode(mode: let mode):
            if state.composerMode.isComposingNewMessage, mode.isEdit {
                handleSaveDraft(isVolatile: true)
            }
            set(mode: mode)
        case .setText(let plainText, let htmlText):
            if let htmlText {
                set(text: plainText, sourceHTML: htmlText)
            } else {
                set(text: plainText)
            }
        case .setFocus:
            state.bindings.composerFocused = true
        case .removeFocus:
            state.bindings.composerFocused = false
        case .clear:
            if let draft = draftService.loadVolatileDraft() {
                handleLoadDraft(draft)
                draftService.clearVolatileDraft()
            } else {
                set(mode: .default)
                set(text: "")
            }
        }
    }
    
    func loadDraft() async {
        if let initialText {
            set(text: initialText)
            set(mode: .default)
            state.bindings.composerFocused = true
        } else {
            guard case let .success(draft) = await draftService.loadDraft(),
                  let draft else {
                return
            }
            handleLoadDraft(draft)
        }
    }
    
    func saveDraft() {
        handleSaveDraft(isVolatile: false)
    }
    
    // MARK: - Private
    
    private func setupComposerIfNeeded() {
        guard !hasAppeared else { return }
        hasAppeared = true
        wysiwygViewModel.setup()
    }
    
    private func handleLoadDraft(_ draft: ComposerDraftProxy) {
        context.composerFormattingEnabled = false
        context.composerExpanded = false
        
        if let html = draft.htmlText,
           let customEmojiHTML = CustomEmojiMessageContent.unmarkingPlainTextDraft(html) {
            set(text: draft.plainText, sourceHTML: customEmojiHTML)
        } else if let html = draft.htmlText {
            set(text: draft.plainText, sourceHTML: html)
        } else {
            set(text: draft.plainText)
        }
        
        switch draft.draftType {
        case .newMessage:
            set(mode: .default)
        case .edit(let eventID):
            set(mode: .edit(originalEventOrTransactionID: .eventID(eventID), type: .default))
        case .reply(let eventID):
            set(mode: .reply(eventID: eventID, replyDetails: .loading(eventID: eventID), isThread: false))
            replyLoadingTask = Task {
                let reply = switch await draftService.getReply(eventID: eventID) {
                case .success(let reply):
                    reply
                case .failure:
                    TimelineItemReply(details: .error(eventID: eventID, message: L10n.commonSomethingWentWrong), isThreaded: false)
                }
                
                guard !Task.isCancelled else {
                    return
                }
                
                set(mode: .reply(eventID: eventID, replyDetails: reply.details, isThread: reply.isThreaded))
            }
        }
    }
    
    private func handleSaveDraft(isVolatile: Bool) {
        let plainText: String
        let htmlText: String?
        let type: ComposerDraftProxy.ComposerDraftType
        
        if wysiwygViewModel.isContentEmpty, state.composerMode == .default {
            if isVolatile {
                draftService.clearVolatileDraft()
            } else {
                Task {
                    await draftService.clearDraft()
                }
            }
            return
        }
        plainText = wysiwygViewModel.content.markdown
        let renderedHTML = renderedCustomEmojiHTML(plain: plainText, html: wysiwygViewModel.content.html)
        htmlText = renderedHTML?.isEmpty == false ? renderedHTML : nil
        
        switch state.composerMode {
        case .default:
            type = .newMessage
        case .edit(.eventID(let originalEventID), .default):
            type = .edit(eventID: originalEventID)
        case .reply(let eventID, _, _):
            type = .reply(eventID: eventID)
        default:
            if isVolatile {
                draftService.clearVolatileDraft()
            } else {
                Task {
                    await draftService.clearDraft()
                }
            }
            return
        }
        
        if isVolatile {
            draftService.saveVolatileDraft(.init(plainText: plainText, htmlText: htmlText, draftType: type))
        } else {
            Task {
                await draftService.saveDraft(.init(plainText: plainText, htmlText: htmlText, draftType: type))
            }
        }
    }
    
    private func sendMessage(plain: String,
                             html: String?,
                             mode: ComposerMode,
                             intentionalMentions: IntentionalMentions,
                             customEmojis: [CustomEmoji] = []) {
        let formattedHTML = renderedCustomEmojiHTML(plain: plain, html: html, customEmojis: customEmojis)
        let action = ComposerToolbarViewModelAction.sendMessage(plain: plain,
                                                                html: formattedHTML,
                                                                mode: mode,
                                                                intentionalMentions: intentionalMentions)
        guard shouldWarnBeforeSendingCustomEmoji(html: formattedHTML) else {
            actionsSubject.send(action)
            return
        }
        
        state.bindings.alertInfo = .init(id: UUID(),
                                         title: UntranslatedL10n.customEmojiMediaWarningTitle,
                                         message: UntranslatedL10n.customEmojiMediaWarningMessage,
                                         primaryButton: .init(title: L10n.actionCancel) { [weak self] in
                                             self?.state.bindings.alertInfo = nil
                                         },
                                         secondaryButton: .init(title: L10n.actionContinue) { [weak self] in
                                             guard let self else { return }
                                             appSettings.hasAcknowledgedCustomEmojiMediaWarning = true
                                             state.bindings.alertInfo = nil
                                             actionsSubject.send(action)
                                         })
    }
    
    private func sendMessageResolvingCustomEmojis(plain: String,
                                                  html: String?,
                                                  mode: ComposerMode,
                                                  intentionalMentions: IntentionalMentions) {
        guard CustomEmojiMessageContent.containsPotentialShortcode(in: plain),
              let emojiProvider else {
            sendMessage(plain: plain, html: html, mode: mode, intentionalMentions: intentionalMentions)
            return
        }
        guard sendMessageTask == nil else { return }
        state.isResolvingCustomEmojis = true
        
        sendMessageTask = Task { [weak self] in
            let customEmojis = await emojiProvider.customEmojis()
            guard !Task.isCancelled, let self else { return }
            sendMessageTask = nil
            state.isResolvingCustomEmojis = false
            sendMessage(plain: plain,
                        html: html,
                        mode: mode,
                        intentionalMentions: intentionalMentions,
                        customEmojis: customEmojis)
        }
    }
    
    private func renderedCustomEmojiHTML(plain: String,
                                         html: String?,
                                         customEmojis: [CustomEmoji] = []) -> String? {
        guard CustomEmojiMessageContent.containsPotentialShortcode(in: plain) else { return html }
        
        var seenShortcodes = Set<String>()
        let availableCustomEmojis = (preservedCustomEmojis + customEmojis + (emojiProvider?.cachedCustomEmojis() ?? []))
            .filter { seenShortcodes.insert($0.shortcode).inserted }
        guard !availableCustomEmojis.isEmpty else { return html }
        
        if let html {
            return CustomEmojiMessageContent.renderingCustomEmojis(in: html, customEmojis: availableCustomEmojis) ?? html
        }
        return CustomEmojiMessageContent.renderingCustomEmojis(inPlainText: plain, customEmojis: availableCustomEmojis)
    }
    
    private func shouldWarnBeforeSendingCustomEmoji(html: String?) -> Bool {
        guard state.isRoomEncrypted,
              !appSettings.hasAcknowledgedCustomEmojiMediaWarning,
              let html else {
            return false
        }
        return !CustomEmojiMessageContent.restoringCustomEmojis(in: html).customEmojis.isEmpty
    }
    
    private func replaceRichComposerText(in range: NSRange, with replacement: String) {
        _ = wysiwygViewModel.replaceText(range: range, replacementText: replacement)
        wysiwygViewModel.applyAtributedContent()
        wysiwygViewModel.updateCompressedHeightIfNeeded()
    }
    
    private func processVoiceMessageAction(_ action: ComposerToolbarVoiceMessageAction) {
        switch action {
        case .startRecording:
            state.bindings.composerFormattingEnabled = false
            actionsSubject.send(.voiceMessage(.startRecording))
        case .stopRecording:
            actionsSubject.send(.voiceMessage(.stopRecording))
        case .cancelRecording:
            actionsSubject.send(.voiceMessage(.cancelRecording))
        case .deleteRecording:
            actionsSubject.send(.voiceMessage(.deleteRecording))
        case .startPlayback:
            actionsSubject.send(.voiceMessage(.startPlayback))
        case .pausePlayback:
            actionsSubject.send(.voiceMessage(.pausePlayback))
        case .scrubPlayback(let scrubbing):
            actionsSubject.send(.voiceMessage(.scrubPlayback(scrubbing: scrubbing)))
        case .seekPlayback(let progress):
            actionsSubject.send(.voiceMessage(.seekPlayback(progress: progress)))
        case .transcribe:
            actionsSubject.send(.voiceMessage(.transcribe))
        case .send:
            break
        }
    }
    
    private func setupMentionsHandling(mentionDisplayHelper: MentionDisplayHelper) {
        wysiwygViewModel.mentionDisplayHelper = mentionDisplayHelper
        
        wysiwygViewModel.mentionReplacer = ComposerMentionReplacer { [weak self] urlString, string in
            guard let self else {
                return NSMutableAttributedString(string: string)
            }
            
            let attributedString: NSMutableAttributedString
            // This is the all room mention special case
            if urlString == PillUtilities.composerAtRoomURLString {
                attributedString = NSMutableAttributedString(string: string, attributes: [.MatrixAllUsersMention: true])
            } else {
                attributedString = NSMutableAttributedString(string: string, attributes: [.link: URL(string: urlString) as Any])
            }
            
            attributedStringBuilder.addMatrixEntityPermalinkAttributesTo(attributedString)
            
            // In RTE mentions don't need to be handled as links
            attributedString.removeAttribute(.link, range: NSRange(location: 0, length: attributedString.length))
            return attributedString
        }
    }
    
    private func handleSuggestion(_ suggestion: SuggestionItem) {
        switch suggestion.suggestionType {
        case let .user(user):
            guard let url = try? URL(string: matrixToUserPermalink(userId: user.id)) else {
                MXLog.error("Could not build user permalink")
                return
            }
            wysiwygViewModel.setMention(url: url.absoluteString, name: user.id, mentionType: .user)
        case .allUsers:
            wysiwygViewModel.setAtRoomMention()
        case let .room(room):
            guard let url = try? URL(string: matrixToRoomAliasPermalink(roomAlias: room.canonicalAlias)) else {
                MXLog.error("Could not build alias permalink")
                return
            }
            wysiwygViewModel.setMention(url: url.absoluteString, name: room.name, mentionType: .room)
        case let .emoji(emoji):
            let replacement = emoji.customEmoji.map { ":\($0.shortcode):" } ?? emoji.unicode
            let currentTrigger = wysiwygViewModel.suggestionPattern?.toElementPattern
            let range = if let currentTrigger, currentTrigger.type == .emoji {
                currentTrigger.range
            } else {
                suggestion.range
            }
            replaceRichComposerText(in: range, with: replacement)
            if let emojiProvider {
                Task {
                    await emojiProvider.markEmojiAsRecentlyUsed(emoji.reactionKey,
                                                                shortcode: emoji.customEmoji?.shortcode)
                }
            }
            completionSuggestionService.setSuggestionTrigger(nil)
        }
    }
    
    private func processIdentityStatusChanges(_ changes: [IdentityStatusChange]) async {
        for change in changes {
            switch change.changedTo {
            case .verificationViolation:
                guard case let .success(member) = await roomProxy.getMember(userID: change.userId) else {
                    MXLog.error("Failed retrieving room member for identity status change: \(change)")
                    continue
                }
                
                identityPinningViolations[change.userId] = member
            default:
                // clear
                identityPinningViolations[change.userId] = nil
            }
        }
        
        state.canSend = identityPinningViolations.isEmpty
    }
    
    private func set(mode: ComposerMode) {
        if state.composerMode.isLoadingReply, state.composerMode.replyEventID != mode.replyEventID {
            replyLoadingTask?.cancel()
        }
        
        guard mode != state.composerMode else { return }
        
        state.composerMode = mode
        switch mode {
        case .default:
            break
        case .recordVoiceMessage, .previewVoiceMessage:
            break
        case .edit, .reply:
            // Focus composer when switching to reply/edit
            state.bindings.composerFocused = true
        }
    }
    
    private func set(text: String, sourceHTML: String? = nil) {
        wysiwygViewModel.textView.flushPills()
        
        if let sourceHTML {
            let restoration = CustomEmojiMessageContent.restoringCustomEmojis(in: sourceHTML, fallbackBody: text)
            preservedCustomEmojis = restoration.customEmojis
            wysiwygViewModel.setHtmlContent(restoration.html)
        } else {
            preservedCustomEmojis = []
            wysiwygViewModel.setMarkdownContent(text)
        }
    }
    
    private func createLinkAlert() {
        let linkAction = wysiwygViewModel.getLinkAction()
        currentLinkData = WysiwygLinkData(range: wysiwygViewModel.attributedContent.selection,
                                          url: linkAction.url ?? "",
                                          text: "")
        
        let urlBinding: Binding<String> = .init { [weak self] in
            self?.currentLinkData?.url ?? ""
        } set: { [weak self] value in
            self?.currentLinkData?.url = value
        }
        
        let textBinding: Binding<String> = .init { [weak self] in
            self?.currentLinkData?.text ?? ""
        } set: { [weak self] value in
            self?.currentLinkData?.text = value
        }
        
        switch linkAction {
        case .createWithText:
            state.bindings.alertInfo = makeCreateWithTextAlertInfo(urlBinding: urlBinding, textBinding: textBinding)
        case .create:
            state.bindings.alertInfo = makeSetUrlAlertInfo(urlBinding: urlBinding, isEdit: false)
        case .edit:
            state.bindings.alertInfo = makeEditChoiceAlertInfo(urlBinding: urlBinding)
        case .disabled:
            break
        }
    }
    
    private func makeCreateWithTextAlertInfo(urlBinding: Binding<String>, textBinding: Binding<String>) -> AlertInfo<UUID> {
        AlertInfo(id: UUID(),
                  title: L10n.richTextEditorCreateLink,
                  primaryButton: AlertInfo<UUID>.AlertButton(title: L10n.actionCancel) {
                      self.restoreComposerSelectedRange()
                  },
                  secondaryButton: AlertInfo<UUID>.AlertButton(title: L10n.actionSave) {
                      self.restoreComposerSelectedRange()
                      self.createLinkWithText()
                      
                  },
                  textFields: [AlertInfo<UUID>.AlertTextField(placeholder: L10n.commonText,
                                                              text: textBinding,
                                                              autoCapitalization: .never,
                                                              autoCorrectionDisabled: false),
                               AlertInfo<UUID>.AlertTextField(placeholder: L10n.richTextEditorUrlPlaceholder,
                                                              text: urlBinding,
                                                              autoCapitalization: .never,
                                                              autoCorrectionDisabled: true)])
    }
    
    private func makeSetUrlAlertInfo(urlBinding: Binding<String>, isEdit: Bool) -> AlertInfo<UUID> {
        AlertInfo(id: UUID(),
                  title: isEdit ? L10n.richTextEditorEditLink : L10n.richTextEditorCreateLink,
                  primaryButton: AlertInfo<UUID>.AlertButton(title: L10n.actionCancel) {
                      self.restoreComposerSelectedRange()
                  },
                  secondaryButton: AlertInfo<UUID>.AlertButton(title: L10n.actionSave) {
                      self.restoreComposerSelectedRange()
                      self.setLink()
                      
                  },
                  textFields: [AlertInfo<UUID>.AlertTextField(placeholder: L10n.richTextEditorUrlPlaceholder,
                                                              text: urlBinding,
                                                              autoCapitalization: .never,
                                                              autoCorrectionDisabled: true)])
    }
    
    private func makeEditChoiceAlertInfo(urlBinding: Binding<String>) -> AlertInfo<UUID> {
        AlertInfo(id: UUID(),
                  title: L10n.richTextEditorEditLink,
                  primaryButton: AlertInfo<UUID>.AlertButton(title: L10n.actionRemove, role: .destructive) {
                      self.restoreComposerSelectedRange()
                      self.removeLinks()
                  },
                  verticalButtons: [AlertInfo<UUID>.AlertButton(title: L10n.actionEdit) {
                      self.state.bindings.alertInfo = nil
                      DispatchQueue.main.async {
                          self.state.bindings.alertInfo = self.makeSetUrlAlertInfo(urlBinding: urlBinding, isEdit: true)
                      }
                  }])
    }
    
    private func restoreComposerSelectedRange() {
        guard let currentLinkData else { return }
        wysiwygViewModel.select(range: currentLinkData.range)
    }
    
    private func setLink() {
        guard let currentLinkData else { return }
        wysiwygViewModel.applyLinkOperation(.setLink(urlString: currentLinkData.url))
    }
    
    private func createLinkWithText() {
        guard let currentLinkData else { return }
        wysiwygViewModel.applyLinkOperation(.createLink(urlString: currentLinkData.url,
                                                        text: currentLinkData.text))
    }
    
    private func removeLinks() {
        wysiwygViewModel.applyLinkOperation(.removeLinks)
    }
    
    private func focusComposerIfHardwareKeyboardConnected() {
        // The simulator always detects the hardware keyboard as connected
        #if !targetEnvironment(simulator)
        if GCKeyboard.coalesced != nil {
            MXLog.info("Hardware keyboard is connected")
            state.bindings.composerFocused = true
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(hardwareKeyboardDidConnect), name: .GCKeyboardDidConnect, object: nil)
        #endif
    }
    
    // periphery:ignore:parameters notification
    @objc private func hardwareKeyboardDidConnect(_ notification: Notification) {
        MXLog.info("Did connect hardware keyboard")
        state.bindings.composerFocused = true
    }
}

private extension LinkAction {
    var url: String? {
        guard case .edit(let url) = self else {
            return nil
        }
        return url
    }
}

private final class ComposerMentionReplacer: MentionReplacer {
    let replacementForMentionClosure: (_ urlString: String, _ text: String) -> (NSAttributedString?)
    
    init(replacementForMentionClosure: @escaping (String, String) -> (NSAttributedString?)) {
        self.replacementForMentionClosure = replacementForMentionClosure
    }
    
    /// There is no internal Markdown to RTE switch implemented yet in the room so this one is never called
    func postProcessMarkdown(in attributedString: NSAttributedString) -> NSAttributedString {
        attributedString
    }
    
    /// There is no internal RTE to Markdown switch implemented yet in the room so this one is never called
    func restoreMarkdown(in attributedString: NSAttributedString) -> String {
        attributedString.string
    }
    
    func replacementForMention(_ url: String, text: String) -> NSAttributedString? {
        replacementForMentionClosure(url, text)
    }
}

// MARK: - Mocks

extension ComposerToolbarViewModel {
    enum MockMode { case editing, recordVoiceMessage, previewVoiceMessage(isUploading: Bool), reply(isLoading: Bool) }
    
    static func mock(focused: Bool = false,
                     message: String = "",
                     mockMode: MockMode? = nil,
                     hasSuggestions: Bool = false,
                     canSend: Bool = true) -> ComposerToolbarViewModel {
        let suggestions: [SuggestionItem] = if hasSuggestions {
            [.init(suggestionType: .user(.init(id: "@user_mention_1:matrix.org", displayName: "User 1", avatarURL: nil)), range: .init(), rawSuggestionText: ""),
             .init(suggestionType: .user(.init(id: "@user_mention_2:matrix.org", displayName: "User 2", avatarURL: .mockMXCUserAvatar)), range: .init(), rawSuggestionText: "")]
        } else {
            []
        }
        
        let roomProxy = JoinedRoomProxyMock(.init())
        
        if !canSend {
            roomProxy.identityStatusChangesPublisher = .init([.init(userId: RoomMemberProxyMock.mockAlice.userID, changedTo: .verificationViolation)])
        }
        
        let wysiwygViewModel = WysiwygComposerViewModel()
        let viewModel = ComposerToolbarViewModel(roomProxy: roomProxy,
                                                 wysiwygViewModel: wysiwygViewModel,
                                                 completionSuggestionService: CompletionSuggestionServiceMock(configuration: .init(suggestions: suggestions)),
                                                 mediaProvider: MediaProviderMock(.init()),
                                                 mentionDisplayHelper: ComposerMentionDisplayHelper.mock,
                                                 appSettings: .volatile(),
                                                 analyticsService: AnalyticsServiceMock(.init()),
                                                 composerDraftService: ComposerDraftServiceMock(.init()))
        viewModel.state.bindings.composerFocused = focused
        viewModel.state.bindings.plainComposerText = NSAttributedString(string: message)
        
        switch mockMode {
        case .editing:
            viewModel.state.composerMode = .edit(originalEventOrTransactionID: .eventID(""), type: .default)
        case .recordVoiceMessage:
            viewModel.state.composerMode = .recordVoiceMessage(state: AudioRecorderState())
        case .previewVoiceMessage(let isUploading):
            viewModel.state.composerMode = .previewVoiceMessage(state: AudioPlayerState(id: .recorderPreview,
                                                                                        title: L10n.commonVoiceMessage,
                                                                                        duration: 10.0),
                                                                waveform: .data(Array(repeating: 1.0, count: 1000)),
                                                                isUploading: isUploading)
        case .reply(let isLoading):
            let replyDetails: TimelineItemReplyDetails = if isLoading {
                .loading(eventID: "")
            } else {
                .loaded(sender: .init(id: "", displayName: "Test"),
                        eventID: "",
                        eventContent: .message(.text(.init(body: "Hello World!"))))
            }
            viewModel.state.composerMode = .reply(eventID: UUID().uuidString, replyDetails: replyDetails, isThread: false)
        case nil:
            break
        }
        
        return viewModel
    }
}

private struct PlainComposerContent {
    let text: String
    let mentionedUserIDs: Set<String>
    let containsAtRoomMention: Bool
}
