//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import HTMLParser
import SwiftUI
import WysiwygComposer

struct RoomScreenCoordinatorParameters {
    let userSession: UserSessionProtocol
    let roomProxy: JoinedRoomProxyProtocol
    var focussedEvent: FocusEvent?
    var sharedText: String?
    let timelineController: TimelineControllerProtocol
    let mediaPlayerProvider: MediaPlayerProviderProtocol
    let emojiProvider: EmojiProviderProtocol
    let linkMetadataProvider: LinkMetadataProviderProtocol
    let completionSuggestionService: CompletionSuggestionServiceProtocol
    let ongoingCallRoomIDPublisher: CurrentValuePublisher<String?, Never>
    let appMediator: AppMediatorProtocol
    let appSettings: AppSettings
    let appHooks: AppHooks
    let analytics: AnalyticsServiceProtocol
    let composerDraftService: ComposerDraftServiceProtocol
    let timelineControllerFactory: TimelineControllerFactoryProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
    var nitroRoomWidgetSessionStore: NitroRoomWidgetSessionStoreProtocol = NitroRoomWidgetSessionStore()
}

enum RoomScreenCoordinatorAction {
    case presentReportContent(itemID: TimelineItemIdentifier, senderID: String)
    case presentMediaUploadPicker(mode: MediaPickerScreenMode, caption: NSAttributedString)
    case presentMediaUploadPreviewScreen(mediaURLs: [URL], caption: NSAttributedString)
    case presentRoomDetails
    case presentLocationPicker
    case presentPollForm(mode: PollFormMode)
    case presentLocationViewer(StaticLocationData)
    case presentLiveLocationViewer(sender: TimelineItemSender?, initialLiveLocationShare: LiveLocationShare?)
    case presentEmojiPicker(selectedEmojis: Set<String>, continuation: EmojiPickerScreenContinuation)
    case presentRoomMemberDetails(userID: String)
    case presentMessageForwarding(forwardingItem: MessageForwardingItem)
    case presentCallScreen(isVoiceCall: Bool)
    case presentPinnedEventsTimeline
    case presentResolveSendFailure(failure: TimelineItemSendFailure.VerifiedUser, sendHandle: SendHandleProxy)
    case presentKnockRequestsList
    case presentThreadList
    case presentNitroTasks(roomID: String, roomName: String)
    case presentNitroCatchUp(roomID: String, roomName: String)
    case presentNitroRoomWidgets([NitroRoomWidget], initialWidgetID: String?)
    case navigateFromNitroRoomWidget(URL)
    case presentNitroTaskCreate(roomID: String)
    case presentThread(threadRootEventID: String, focussedEventID: String?)
    case presentRoom(roomID: String, via: [String])
}

final class RoomScreenCoordinator: CoordinatorProtocol {
    private var roomViewModel: RoomScreenViewModelProtocol
    private var timelineViewModel: TimelineViewModelProtocol
    private var composerViewModel: ComposerToolbarViewModelProtocol
    private let appSettings: AppSettings
    private let roomID: String
    private let userID: String
    private let nitroRoomWidgetSessionStore: NitroRoomWidgetSessionStoreProtocol
    
    private var cancellables = Set<AnyCancellable>()
    private var customEmojiPickerCancellable: AnyCancellable?
    private var nitroRoomWidgetCancellable: AnyCancellable?
    private var nitroRoomWidgetsCoordinator: NitroRoomWidgetsScreenCoordinator?
    private let nitroRoomWidgetPanelController = NitroRoomWidgetPanelController()
    
    private let actionsSubject: PassthroughSubject<RoomScreenCoordinatorAction, Never> = .init()
    var actions: AnyPublisher<RoomScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: RoomScreenCoordinatorParameters) {
        appSettings = parameters.appSettings
        roomID = parameters.roomProxy.id
        userID = parameters.userSession.clientProxy.userID
        nitroRoomWidgetSessionStore = parameters.nitroRoomWidgetSessionStore
        
        var selectedPinnedEventID: String?
        if let focussedEvent = parameters.focussedEvent {
            selectedPinnedEventID = focussedEvent.shouldSetPin ? focussedEvent.eventID : nil
        }
        
        roomViewModel = RoomScreenViewModel(userSession: parameters.userSession,
                                            roomProxy: parameters.roomProxy,
                                            initialSelectedPinnedEventID: selectedPinnedEventID,
                                            ongoingCallRoomIDPublisher: parameters.ongoingCallRoomIDPublisher,
                                            appSettings: parameters.appSettings,
                                            appHooks: parameters.appHooks,
                                            analyticsService: parameters.analytics,
                                            userIndicatorController: parameters.userIndicatorController)
        
        timelineViewModel = TimelineViewModel(roomProxy: parameters.roomProxy,
                                              focussedEventID: parameters.focussedEvent?.eventID,
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
        let composerViewModel = ComposerToolbarViewModel(initialText: parameters.sharedText,
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
        self.composerViewModel = composerViewModel
    }
    
    // MARK: - Public
    
    func start() {
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
                    roomViewModel.displayMediaPreview(mediaPreviewViewModel)
                case .displayLocationPicker:
                    actionsSubject.send(.presentLocationPicker)
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
                case .displayLocation(let location):
                    actionsSubject.send(.presentLocationViewer(location))
                case .displayLiveLocation(let sender, let initialLiveLocationShare):
                    actionsSubject.send(.presentLiveLocationViewer(sender: sender, initialLiveLocationShare: initialLiveLocationShare))
                case .displayResolveSendFailure(let failure, let sendHandle):
                    actionsSubject.send(.presentResolveSendFailure(failure: failure, sendHandle: sendHandle))
                case .displayThread(let itemID):
                    guard let eventID = itemID.eventID else {
                        fatalError("A thread root has always an eventID")
                    }
                    actionsSubject.send(.presentThread(threadRootEventID: eventID, focussedEventID: nil))
                case .composer(let action):
                    composerViewModel.process(timelineAction: action)
                case .hasScrolled(direction: let direction):
                    roomViewModel.timelineHasScrolled(direction: direction)
                case .displayRoom(let roomID, let via):
                    actionsSubject.send(.presentRoom(roomID: roomID, via: via))
                case .presentCallScreen(let isVoiceCall):
                    actionsSubject.send(.presentCallScreen(isVoiceCall: isVoiceCall))
                case .viewInRoomTimeline, .displayMediaDetails:
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
        
        setupRoomViewModelActions()
        
        // Loading the draft requires the subscriptions to be set up first otherwise
        // the room won't be be able to propagate the information to the composer.
        composerViewModel.start()
    }
    
    private func setupRoomViewModelActions() {
        roomViewModel.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .focusEvent(eventID: let eventID):
                    focusOnEvent(FocusEvent(eventID: eventID, shouldSetPin: false))
                case .displayPinnedEventsTimeline:
                    actionsSubject.send(.presentPinnedEventsTimeline)
                case .displayRoomDetails:
                    actionsSubject.send(.presentRoomDetails)
                case .displayCall(let isVoiceCall):
                    actionsSubject.send(.presentCallScreen(isVoiceCall: isVoiceCall))
                case .removeComposerFocus:
                    composerViewModel.process(timelineAction: .removeFocus)
                case .displayKnockRequests:
                    actionsSubject.send(.presentKnockRequestsList)
                case .displayRoom(let roomID, let via):
                    actionsSubject.send(.presentRoom(roomID: roomID, via: via))
                case .displayMessageForwarding(let forwardingItem):
                    actionsSubject.send(.presentMessageForwarding(forwardingItem: forwardingItem))
                case .displayThreadList:
                    actionsSubject.send(.presentThreadList)
                case .displayNitroTasks(let roomID, let roomName):
                    actionsSubject.send(.presentNitroTasks(roomID: roomID, roomName: roomName))
                case .displayNitroCatchUp(let roomID, let roomName):
                    actionsSubject.send(.presentNitroCatchUp(roomID: roomID, roomName: roomName))
                case .displayNitroRoomWidgets(let widgets):
                    actionsSubject.send(.presentNitroRoomWidgets(widgets, initialWidgetID: nil))
                case .displayPrimaryNitroRoomWidget(let widgets):
                    let activeWidgetID = nitroRoomWidgetsCoordinator?.context.viewState.destination.widgetID
                    let initialWidgetID = activeWidgetID ?? nitroRoomWidgetSessionStore.primaryWidgetID(in: widgets, for: roomID)
                    actionsSubject.send(.presentNitroRoomWidgets(widgets, initialWidgetID: initialWidgetID))
                case .displayThread(let threadRootEventID, let focussedEventID):
                    actionsSubject.send(.presentThread(threadRootEventID: threadRootEventID, focussedEventID: focussedEventID))
                case .stopLiveLocationSharing:
                    Task { [weak self] in await self?.timelineViewModel.stopLiveLocationSharing() }
                case .displayLiveLocation:
                    actionsSubject.send(.presentLiveLocationViewer(sender: nil, initialLiveLocationShare: nil))
                }
            }
            .store(in: &cancellables)
    }
    
    func focusOnEvent(_ focussedEvent: FocusEvent) {
        let eventID = focussedEvent.eventID
        if focussedEvent.shouldSetPin {
            roomViewModel.setSelectedPinnedEventID(eventID)
        }
        Task { await timelineViewModel.focusOnEvent(eventID: eventID) }
    }
    
    /// Sets the banner to selection to a specific event ID, even if not visible in the main timeline (like a threaded event).
    func setSelectedPin(eventID: String) {
        roomViewModel.setSelectedPinnedEventID(eventID)
    }
    
    func shareText(_ string: String) {
        composerViewModel.process(timelineAction: .setMode(mode: .default)) // Make sure we're not e.g. replying.
        composerViewModel.process(timelineAction: .setText(plainText: string, htmlText: nil))
        composerViewModel.process(timelineAction: .setFocus)
    }
    
    func presentNitroRoomWidgets(_ widgets: [NitroRoomWidget],
                                 colorScheme: ColorScheme,
                                 restoring session: NitroRoomWidgetSession? = nil,
                                 driverFactory: @escaping () -> NitroRoomWidgetDriverProtocol?) {
        guard !widgets.isEmpty else { return }
        
        tearDownNitroRoomWidgets()
        let coordinator = NitroRoomWidgetsScreenCoordinator(parameters: .init(widgets: widgets,
                                                                              initialWidgetID: session?.widgetID,
                                                                              colorScheme: colorScheme,
                                                                              driverFactory: driverFactory))
        nitroRoomWidgetsCoordinator = coordinator
        nitroRoomWidgetCancellable = coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .dismiss:
                    dismissNitroRoomWidgets()
                case .navigate(let url):
                    suspendNitroRoomWidgets()
                    actionsSubject.send(.navigateFromNitroRoomWidget(url))
                }
            }
        coordinator.start()
        let layout = session?.layout ?? .regular
        nitroRoomWidgetPanelController.present(context: coordinator.context, layout: layout)
        nitroRoomWidgetSessionStore.setSession(.init(widgetID: coordinator.context.viewState.destination.widgetID,
                                                     layout: layout),
                                               for: roomID)
    }
    
    func stop() {
        suspendNitroRoomWidgets()
        timelineViewModel.stop()
        composerViewModel.stop()
        roomViewModel.stop()
    }
    
    private func dismissNitroRoomWidgets() {
        if let widgetID = nitroRoomWidgetsCoordinator?.context.viewState.destination.widgetID {
            nitroRoomWidgetSessionStore.setPreferredWidgetID(widgetID, for: roomID)
        }
        nitroRoomWidgetSessionStore.removeSession(for: roomID)
        tearDownNitroRoomWidgets()
    }
    
    private func suspendNitroRoomWidgets() {
        if let nitroRoomWidgetsCoordinator {
            nitroRoomWidgetSessionStore.setSession(.init(widgetID: nitroRoomWidgetsCoordinator.context.viewState.destination.widgetID,
                                                         layout: nitroRoomWidgetPanelController.layout),
                                                   for: roomID)
        }
        tearDownNitroRoomWidgets()
    }
    
    private func tearDownNitroRoomWidgets() {
        nitroRoomWidgetPanelController.dismiss()
        nitroRoomWidgetsCoordinator?.stop()
        nitroRoomWidgetsCoordinator = nil
        nitroRoomWidgetCancellable = nil
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
        
        return AnyView(RoomScreen(context: roomViewModel.context,
                                  timelineContext: timelineViewModel.context,
                                  composerToolbar: composerToolbar,
                                  nitroRoomWidgetPanelController: nitroRoomWidgetPanelController))
    }
}

enum ComposerConstant {
    static let minHeight: CGFloat = 22
    static let maxHeight: CGFloat = 250
    static let allowedHeightRange = minHeight...maxHeight
    static let translationThreshold: CGFloat = 60
}
