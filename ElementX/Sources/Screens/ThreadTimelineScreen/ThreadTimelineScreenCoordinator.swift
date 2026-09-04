//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import HTMLParser
import SwiftUI
import WysiwygComposer

struct ThreadTimelineScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
    let roomProxy: JoinedRoomProxyProtocol
    let focussedEventID: String?
    let timelineController: TimelineControllerProtocol
    let mediaPlayerProvider: MediaPlayerProviderProtocol
    let emojiProvider: EmojiProviderProtocol
    let linkMetadataProvider: LinkMetadataProviderProtocol
    let completionSuggestionService: CompletionSuggestionServiceProtocol
    let appMediator: AppMediatorProtocol
    let appSettings: AppSettings
    let analytics: AnalyticsServiceProtocol
    let composerDraftService: ComposerDraftServiceProtocol
    let timelineControllerFactory: TimelineControllerFactoryProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum ThreadTimelineScreenCoordinatorAction {
    case presentReportContent(itemID: TimelineItemIdentifier, senderID: String)
    case presentMediaUploadPicker(mode: MediaPickerScreenMode, caption: NSAttributedString)
    case presentMediaUploadPreviewScreen(mediaURLs: [URL], caption: NSAttributedString)
    case presentLocationPicker
    case presentLocationViewer(StaticLocationData)
    case presentLiveLocationViewer(sender: TimelineItemSender, initialLiveLocationShare: LiveLocationShare)
    case presentPollForm(mode: PollFormMode)
    case presentEmojiPicker(selectedEmojis: Set<String>, continuation: EmojiPickerScreenContinuation)
    case presentRoomMemberDetails(userID: String)
    case presentMessageForwarding(forwardingItem: MessageForwardingItem)
    case presentResolveSendFailure(failure: TimelineItemSendFailure.VerifiedUser, sendHandle: SendHandleProxy)
    case presentNitroTaskCreate(roomID: String)
}

final class ThreadTimelineScreenCoordinator: CoordinatorProtocol {
    private let viewModel: ThreadTimelineScreenViewModelProtocol
    private let timelineViewModel: TimelineViewModelProtocol
    private var composerViewModel: ComposerToolbarViewModelProtocol
    private let appSettings: AppSettings
    private let roomID: String
    private let userID: String
    
    private var cancellables = Set<AnyCancellable>()
    private var customEmojiPickerCancellable: AnyCancellable?
    
    private let actionsSubject: PassthroughSubject<ThreadTimelineScreenCoordinatorAction, Never> = .init()
    var actions: AnyPublisher<ThreadTimelineScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: ThreadTimelineScreenCoordinatorParameters) {
        appSettings = parameters.appSettings
        roomID = parameters.roomProxy.id
        userID = parameters.userSession.clientProxy.userID
        
        viewModel = ThreadTimelineScreenViewModel(roomProxy: parameters.roomProxy, userSession: parameters.userSession)
        
        timelineViewModel = TimelineViewModel(roomProxy: parameters.roomProxy,
                                              focussedEventID: parameters.focussedEventID,
                                              timelineController: parameters.timelineController,
                                              userSession: parameters.userSession,
                                              mediaPlayerProvider: parameters.mediaPlayerProvider,
                                              userIndicatorController: parameters.userIndicatorController,
                                              appMediator: parameters.appMediator,
                                              appSettings: parameters.appSettings,
                                              analyticsService: parameters.analytics,
                                              emojiProvider: parameters.emojiProvider,
                                              linkMetadataProvider: parameters.linkMetadataProvider,
                                              timelineControllerFactory: parameters.timelineControllerFactory)
        
        let wysiwygViewModel = WysiwygComposerViewModel(minHeight: ComposerConstant.minHeight,
                                                        maxCompressedHeight: ComposerConstant.maxHeight,
                                                        maxExpandedHeight: ComposerConstant.maxHeight,
                                                        parserStyle: .elementX)
        
        composerViewModel = ComposerToolbarViewModel(initialText: nil,
                                                     roomProxy: parameters.roomProxy,
                                                     wysiwygViewModel: wysiwygViewModel,
                                                     completionSuggestionService: parameters.completionSuggestionService,
                                                     mediaProvider: parameters.userSession.mediaProvider,
                                                     mentionDisplayHelper: ComposerMentionDisplayHelper(timelineContext: timelineViewModel.context),
                                                     appSettings: parameters.appSettings,
                                                     analyticsService: parameters.analytics,
                                                     composerDraftService: parameters.composerDraftService,
                                                     emojiProvider: parameters.emojiProvider,
                                                     nitroTasksEnabled: NitroConfiguration.isEnabled && parameters.userSession.clientProxy is NitroClientProxyProtocol)
    }
    
    func start() {
        viewModel.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .displayMessageForwarding(let forwardingItem):
                    actionsSubject.send(.presentMessageForwarding(forwardingItem: forwardingItem))
                }
            }
            .store(in: &cancellables)
        
        timelineViewModel.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .displayEmojiPicker(let selectedEmojis, let continuation):
                    actionsSubject.send(.presentEmojiPicker(selectedEmojis: selectedEmojis, continuation: continuation))
                case .displayReportContent(let itemID, let senderID):
                    actionsSubject.send(.presentReportContent(itemID: itemID, senderID: senderID))
                case .displayCameraPicker:
                    actionsSubject.send(.presentMediaUploadPicker(mode: .init(source: .camera, selectionType: .multiple(galleryEnabled: appSettings.galleryEnabled)),
                                                                  caption: composerViewModel.context.plainComposerText))
                case .displayMediaPicker:
                    actionsSubject.send(.presentMediaUploadPicker(mode: .init(source: .photoLibrary, selectionType: .multiple(galleryEnabled: appSettings.galleryEnabled)),
                                                                  caption: composerViewModel.context.plainComposerText))
                case .displayDocumentPicker:
                    actionsSubject.send(.presentMediaUploadPicker(mode: .init(source: .documents(), selectionType: .multiple(galleryEnabled: appSettings.galleryEnabled)),
                                                                  caption: composerViewModel.context.plainComposerText))
                case .displayMediaPreview(let mediaPreviewViewModel):
                    viewModel.displayMediaPreview(mediaPreviewViewModel)
                case .displayLocationPicker:
                    actionsSubject.send(.presentLocationPicker)
                case .displayLocation(let location):
                    actionsSubject.send(.presentLocationViewer(location))
                case .displayLiveLocation(let sender, let initialLiveLocationShare):
                    actionsSubject.send(.presentLiveLocationViewer(sender: sender, initialLiveLocationShare: initialLiveLocationShare))
                case .displayNewPollForm:
                    actionsSubject.send(.presentPollForm(mode: .new(topic: composerViewModel.context.plainComposerText.string)))
                case .displayEditPollForm(let eventID, let poll):
                    actionsSubject.send(.presentPollForm(mode: .edit(eventID: eventID, poll: poll)))
                case .displayMediaUploadPreviewScreen(let mediaURLs):
                    actionsSubject.send(.presentMediaUploadPreviewScreen(mediaURLs: mediaURLs,
                                                                         caption: composerViewModel.context.plainComposerText))
                case .displaySenderDetails(userID: let userID):
                    actionsSubject.send(.presentRoomMemberDetails(userID: userID))
                case .displayMessageForwarding(let forwardingItem):
                    actionsSubject.send(.presentMessageForwarding(forwardingItem: forwardingItem))
                case .displayResolveSendFailure(let failure, let sendHandle):
                    actionsSubject.send(.presentResolveSendFailure(failure: failure,
                                                                   sendHandle: sendHandle))
                case .hasScrolled, .displayRoom, .displayMediaDetails, .presentCallScreen:
                    break
                case .composer(let action):
                    composerViewModel.process(timelineAction: action)
                case .viewInRoomTimeline, .displayThread:
                    fatalError("The action: \(action) should not be sent to this coordinator")
                }
            }
            .store(in: &cancellables)
        
        composerViewModel.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                if case .attach(.customEmoji) = action {
                    presentCustomEmojiPicker()
                } else {
                    timelineViewModel.process(composerAction: action)
                }
            }
            .store(in: &cancellables)
        
        // Loading the draft requires the subscriptions to be set up first otherwise
        // the room won't be be able to propagate the information to the composer.
        composerViewModel.start()
    }
    
    func stop() {
        timelineViewModel.stop()
        composerViewModel.stop()
        viewModel.stop()
    }
    
    private func presentCustomEmojiPicker() {
        let (stream, continuation) = AsyncStream<EmojiPickerEmojiViewData>.makeStream()
        actionsSubject.send(.presentEmojiPicker(selectedEmojis: [], continuation: continuation))
        
        customEmojiPickerCancellable = Task { [weak self] in
            for await emoji in stream {
                self?.composerViewModel.sendEmoji(emoji)
            }
        }
        .asCancellable()
    }
    
    func toPresentable() -> AnyView {
        let nitroGIFPickerConfiguration = NitroConfiguration.giphyAPIKey.map { apiKey in
            NitroGIFPickerPresentationConfiguration(userID: userID,
                                                    serviceConfiguration: .init(apiKey: apiKey, rating: .pg13, resultLimit: 24)) { [weak self] url in
                guard let self else { return }
                actionsSubject.send(.presentMediaUploadPreviewScreen(mediaURLs: [url],
                                                                     caption: composerViewModel.context.plainComposerText))
            }
        }
        let composerToolbar = ComposerToolbar(context: composerViewModel.context,
                                              onCreateNitroTask: { [weak self] in
                                                  guard let self else { return }
                                                  actionsSubject.send(.presentNitroTaskCreate(roomID: roomID))
                                              },
                                              nitroGIFPickerConfiguration: nitroGIFPickerConfiguration)
        
        return AnyView(ThreadTimelineScreen(context: viewModel.context,
                                            timelineContext: timelineViewModel.context,
                                            composerToolbar: composerToolbar))
    }
    
    func focusOnEvent(eventID: String) {
        Task { await timelineViewModel.focusOnEvent(eventID: eventID) }
    }
}
