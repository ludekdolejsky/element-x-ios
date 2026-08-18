//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import Combine
import Compound
import SwiftState
import SwiftUI

enum UserSessionFlowCoordinatorAction {
    case logout
    case clearCache
    /// Logout and disable App Lock without any confirmation. The user forgot their PIN.
    case forceLogout
}

class UserSessionFlowCoordinator: FlowCoordinatorProtocol {
    enum HomeTab: Hashable, Sendable { case chats, spaces, tasks, search }
    
    private static let tasksAutomaticRefreshDebounceSeconds = 1
    private static let tasksAutomaticRefreshIntervalSeconds = 30
    
    private let navigationRootCoordinator: NavigationRootCoordinator
    private let navigationTabCoordinator: NavigationTabCoordinator<HomeTab>
    private let appLockService: AppLockServiceProtocol
    private let flowParameters: CommonFlowParameters
    // periphery:ignore - retaining purpose
    private let presenceService: PresenceService
    
    private var userSession: UserSessionProtocol {
        flowParameters.userSession
    }
    
    private let onboardingFlowCoordinator: OnboardingFlowCoordinator
    private let onboardingStackCoordinator: NavigationStackCoordinator
    private let chatsTabFlowCoordinator: ChatsTabFlowCoordinator
    private let chatsTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails
    private let spacesTabFlowCoordinator: SpacesTabFlowCoordinator
    private let spacesTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails
    
    private let tasksScreenCoordinator: NitroTasksScreenCoordinator?
    private let tasksTabNavigationStackCoordinator: NavigationStackCoordinator?
    private let tasksTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails?
    
    private let searchScreenCoordinator: SearchScreenCoordinator?
    private let searchTabNavigationStackCoordinator: NavigationStackCoordinator?
    private let searchTabDetails: NavigationTabCoordinator<HomeTab>.TabDetails?
    
    private var settingsFlowCoordinator: SettingsFlowCoordinator?
    
    enum State: StateType {
        /// The state machine hasn't started.
        case initial
        /// The root screen for this flow.
        case tabBar
        /// Showing the settings screen.
        case settingsScreen
    }
    
    enum Event: EventType {
        /// The flow is being started.
        case start
        
        /// Request presentation of the settings screen.
        case showSettingsScreen
        /// The settings screen has been dismissed.
        case dismissedSettingsScreen
    }
    
    private let stateMachine: StateMachine<State, Event>
    private var cancellables: Set<AnyCancellable> = []
    private var tasksTabObservationTask: Task<Void, Never>?
    
    private let actionsSubject: PassthroughSubject<UserSessionFlowCoordinatorAction, Never> = .init()
    var actionsPublisher: AnyPublisher<UserSessionFlowCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(isNewLogin: Bool,
         navigationRootCoordinator: NavigationRootCoordinator,
         appLockService: AppLockServiceProtocol,
         flowParameters: CommonFlowParameters) {
        self.navigationRootCoordinator = navigationRootCoordinator
        self.appLockService = appLockService
        self.flowParameters = flowParameters
        presenceService = PresenceService(clientProxy: flowParameters.userSession.clientProxy,
                                          appSettings: flowParameters.appSettings)
        
        navigationTabCoordinator = NavigationTabCoordinator()
        navigationRootCoordinator.setRootCoordinator(navigationTabCoordinator)
        
        let chatsSplitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: flowParameters.appSettings.hideBrandChrome))
        chatsTabFlowCoordinator = ChatsTabFlowCoordinator(navigationSplitCoordinator: chatsSplitCoordinator,
                                                          flowParameters: flowParameters)
        chatsTabDetails = .init(tag: HomeTab.chats, title: L10n.screenHomeTabChats, icon: \.chat, selectedIcon: \.chatSolid)
        chatsTabDetails.navigationSplitCoordinator = chatsSplitCoordinator
        
        let spacesSplitCoordinator = NavigationSplitCoordinator(placeholderCoordinator: PlaceholderScreenCoordinator(hideBrandChrome: flowParameters.appSettings.hideBrandChrome))
        spacesTabFlowCoordinator = SpacesTabFlowCoordinator(navigationSplitCoordinator: spacesSplitCoordinator,
                                                            flowParameters: flowParameters)
        spacesTabDetails = .init(tag: HomeTab.spaces, title: L10n.screenHomeTabSpaces, icon: \.space, selectedIcon: \.spaceSolid)
        spacesTabDetails.navigationSplitCoordinator = spacesSplitCoordinator
        
        if NitroConfiguration.isEnabled,
           let clientProxy = flowParameters.userSession.clientProxy as? NitroClientProxyProtocol {
            let coordinator = NitroTasksScreenCoordinator(parameters: .init(taskService: clientProxy.nitroTaskService))
            let stackCoordinator = NavigationStackCoordinator()
            stackCoordinator.setRootCoordinator(coordinator)
            
            tasksScreenCoordinator = coordinator
            tasksTabNavigationStackCoordinator = stackCoordinator
            tasksTabDetails = .init(tag: HomeTab.tasks,
                                    title: UntranslatedL10n.screenNitroTasksTitleIos,
                                    icon: \.checkCircle,
                                    selectedIcon: \.checkCircleSolid)
        } else {
            tasksScreenCoordinator = nil
            tasksTabNavigationStackCoordinator = nil
            tasksTabDetails = nil
        }
        
        if flowParameters.appSettings.globalSearchEnabled, #available(iOS 26.0, *) {
            let searchCoordinator = SearchScreenCoordinator(parameters: .init(roomSummaryProvider: flowParameters.userSession.clientProxy.alternateRoomSummaryProvider,
                                                                              clientProxy: flowParameters.userSession.clientProxy,
                                                                              mediaProvider: flowParameters.userSession.mediaProvider,
                                                                              userIndicatorController: flowParameters.userIndicatorController))
            let searchStackCoordinator = NavigationStackCoordinator()
            searchStackCoordinator.setRootCoordinator(searchCoordinator)
            
            searchScreenCoordinator = searchCoordinator
            searchTabNavigationStackCoordinator = searchStackCoordinator
            searchTabDetails = .init(tag: HomeTab.search, title: UntranslatedL10n.screenHomeTabSearch, icon: \.search, selectedIcon: \.search, isSearch: true)
        } else {
            searchScreenCoordinator = nil
            searchTabNavigationStackCoordinator = nil
            searchTabDetails = nil
        }
        
        onboardingStackCoordinator = NavigationStackCoordinator()
        onboardingFlowCoordinator = OnboardingFlowCoordinator(isNewLogin: isNewLogin,
                                                              appLockService: appLockService,
                                                              navigationStackCoordinator: onboardingStackCoordinator,
                                                              flowParameters: flowParameters)
        
        var tabs: [NavigationTabCoordinator<HomeTab>.Tab] = [
            .init(coordinator: chatsSplitCoordinator, details: chatsTabDetails),
            .init(coordinator: spacesSplitCoordinator, details: spacesTabDetails)
        ]
        if let tasksTabNavigationStackCoordinator, let tasksTabDetails {
            tabs.append(.init(coordinator: tasksTabNavigationStackCoordinator, details: tasksTabDetails))
        }
        if let searchTabNavigationStackCoordinator, let searchTabDetails {
            tabs.append(.init(coordinator: searchTabNavigationStackCoordinator, details: searchTabDetails))
        }
        navigationTabCoordinator.setTabs(tabs)
        
        stateMachine = flowParameters.stateMachineFactory.makeUserSessionFlowStateMachine(state: .initial)
        configureStateMachine()
        
        setupObservers()
    }
    
    func start(animated: Bool) {
        stateMachine.tryEvent(.start)
    }
    
    func stop() {
        tasksTabObservationTask?.cancel()
        tasksTabObservationTask = nil
        chatsTabFlowCoordinator.stop()
    }
    
    isolated deinit {
        tasksTabObservationTask?.cancel()
    }
    
    func handleAppRoute(_ appRoute: AppRoute, animated: Bool) {
        MXLog.info("Handling app route: \(appRoute)")
        
        switch appRoute {
        case .accountProvisioningLink, .oAuthCallback:
            break // We always ignore these flows when logged in.
        case .settings, .chatBackupSettings:
            if ProcessInfo.processInfo.isiOSAppOnMac, flowParameters.windowManager.secondaryWindowsEnabled {
                startSettingsFlow(detached: true)
            } else {
                if stateMachine.state != .settingsScreen {
                    stateMachine.tryEvent(.showSettingsScreen)
                }
                settingsFlowCoordinator?.handleAppRoute(appRoute, animated: animated)
            }
        case .call(let roomID, let isVoiceCall):
            Task { await presentCallScreen(roomID: roomID, isVoiceCall: isVoiceCall) }
        case .roomList, .room, .roomAlias, .childRoom, .childRoomAlias,
             .roomDetails, .roomMemberDetails, .userProfile,
             .event, .eventOnRoomAlias, .childEvent, .childEventOnRoomAlias,
             .share, .transferOwnership, .thread:
            clearPresentedSheets(animated: animated) // Make sure the presented route is visible.
            chatsTabFlowCoordinator.handleAppRoute(appRoute, animated: animated)
            if navigationTabCoordinator.selectedTab != .chats {
                navigationTabCoordinator.selectedTab = .chats
            }
        case .search:
            // Switch to the dedicated search tab when it's available (iOS 26 + flag), otherwise ignore.
            if searchTabNavigationStackCoordinator != nil {
                navigationTabCoordinator.selectedTab = .search
            }
        }
    }
    
    func clearRoute(animated: Bool) {
        clearPresentedSheets(animated: animated)
        chatsTabFlowCoordinator.clearRoute(animated: animated)
    }
    
    /// Clearing routes is more complicated than it first seems. When passing routes
    /// to the chats flow we can't clear all routes as e.g. childRoom/childEvent etc
    /// expect to push into the existing stack. But we do need to hide any sheets that
    /// might cover up the presented route. BUT! We probably shouldn't dismiss onboarding
    /// or verification flows until they're complete… This needs more thought before we
    /// codify it all into the state machine.
    private func clearPresentedSheets(animated: Bool) {
        switch stateMachine.state {
        case .initial, .tabBar:
            break
        case .settingsScreen:
            navigationTabCoordinator.setSheetCoordinator(nil, animated: animated)
        }
    }
    
    func isDisplayingRoomScreen(withRoomID roomID: String) -> Bool {
        guard navigationTabCoordinator.selectedTab == .chats else { return false }
        return chatsTabFlowCoordinator.isDisplayingRoomScreen(withRoomID: roomID)
    }
    
    // MARK: - Private
    
    private func configureStateMachine() {
        stateMachine.addRoutes(event: .start, transitions: [.initial => .tabBar]) { [weak self] _ in
            guard let self else { return }
            
            chatsTabFlowCoordinator.start()
            spacesTabFlowCoordinator.start()
            attemptStartingOnboarding()
        }
        
        stateMachine.addRoutes(event: .showSettingsScreen, transitions: [.tabBar => .settingsScreen]) { [weak self] _ in
            self?.startSettingsFlow(detached: false)
        }
        stateMachine.addRoutes(event: .dismissedSettingsScreen, transitions: [.settingsScreen => .tabBar]) { [weak self] _ in
            self?.settingsFlowCoordinator = nil
        }
        
        stateMachine.addErrorHandler { context in
            fatalError("Unexpected transition: \(context)")
        }
    }
    
    // swiftlint:disable:next function_body_length
    private func setupObservers() {
        chatsTabFlowCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .switchToChatsTab:
                    navigationTabCoordinator.selectedTab = .chats
                case .showSettings:
                    handleAppRoute(.settings, animated: true)
                case .showChatBackupSettings:
                    handleAppRoute(.chatBackupSettings, animated: true)
                case .sessionVerification(let flow):
                    presentSessionVerificationScreen(flow: flow)
                case .showCallScreen(let roomProxy, let isVoiceCall):
                    presentCallScreen(roomProxy: roomProxy, voiceOnly: isVoiceCall)
                case .showNitroTasks(let roomID, let roomName):
                    showNitroTasks(roomID: roomID, roomName: roomName)
                case .hideCallScreenOverlay:
                    hideCallScreenOverlay()
                case .logout:
                    Task { await self.runLogoutFlow() }
                }
            }
            .store(in: &cancellables)
        
        spacesTabFlowCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .presentCallScreen(let roomProxy, let isVoiceCall):
                    presentCallScreen(roomProxy: roomProxy, voiceOnly: isVoiceCall)
                case .showNitroTasks(let roomID, let roomName):
                    showNitroTasks(roomID: roomID, roomName: roomName)
                case .verifyUser(let userID):
                    presentSessionVerificationScreen(flow: .userInitiator(userID: userID))
                case .showSettings:
                    stateMachine.tryEvent(.showSettingsScreen)
                }
            }
            .store(in: &cancellables)
        
        if let tasksScreenCoordinator {
            tasksScreenCoordinator.actionsPublisher
                .sink { [weak self] action in
                    guard let self else { return }
                    switch action {
                    case .presentCreate(let initialRoomID):
                        presentNitroTaskCreate(initialRoomID: initialRoomID)
                    case .presentReminders:
                        presentNitroReminders()
                    case .presentReminder(let task):
                        Task { await self.presentNitroTaskReminder(task) }
                    case .openTask(let task):
                        tasksTabNavigationStackCoordinator?.popToRoot(animated: false)
                        handleAppRoute(.event(eventID: task.id, roomID: task.roomID, via: []), animated: true)
                    case .openSource(let task):
                        openNitroTaskSource(task)
                    }
                }
                .store(in: &cancellables)
            
            let selectedTabs = navigationTabCoordinator.observe(\.selectedTab)
            tasksTabObservationTask = Task { [weak tasksScreenCoordinator] in
                for await selectedTab in selectedTabs {
                    guard !Task.isCancelled else { return }
                    guard selectedTab == .tasks else { continue }
                    tasksScreenCoordinator?.refresh()
                }
            }
            
            userSession.clientProxy.staticRoomSummaryProvider.roomListPublisher
                .dropFirst()
                .debounce(for: .seconds(Self.tasksAutomaticRefreshDebounceSeconds), scheduler: DispatchQueue.main)
                .throttle(for: .seconds(Self.tasksAutomaticRefreshIntervalSeconds), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self, weak tasksScreenCoordinator] _ in
                    guard self?.navigationTabCoordinator.selectedTab == .tasks else { return }
                    tasksScreenCoordinator?.refresh()
                }
                .store(in: &cancellables)
        }
        
        userSession.sessionSecurityStatePublisher
            .map(\.verificationState)
            .filter { $0 != .unknown }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                
                attemptStartingOnboarding()
                setupSessionVerificationRequestsObserver()
            }
            .store(in: &cancellables)
        
        let reachabilityNotificationID = "io.element.elementx.reachability.notification"
        userSession.clientProxy.homeserverReachabilityPublisher.removeDuplicates()
            .combineLatest(flowParameters.appMediator.networkMonitor.reachabilityPublisher.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] homeserverReachability, networkReachability in
                MXLog.info("Homeserver reachability: \(homeserverReachability)")
                
                guard let self else { return }
                switch (networkReachability, homeserverReachability) {
                case (.unreachable, _):
                    flowParameters.userIndicatorController.submitIndicator(.init(id: reachabilityNotificationID,
                                                                                 title: L10n.commonOffline,
                                                                                 persistent: true))
                case (.reachable, .unreachable):
                    flowParameters.userIndicatorController.submitIndicator(.init(id: reachabilityNotificationID,
                                                                                 title: L10n.commonServerUnreachable,
                                                                                 persistent: true))
                // Don't alarm the user while we've intentionally suspended the client.
                case (.reachable, .reachable), (.reachable, .suspended):
                    flowParameters.userIndicatorController.retractIndicatorWithId(reachabilityNotificationID)
                }
            }
            .store(in: &cancellables)
        
        onboardingFlowCoordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .requestPresentation(let animated):
                    navigationTabCoordinator.setFullScreenCoverCoordinator(onboardingStackCoordinator, animated: animated)
                case .dismiss:
                    navigationTabCoordinator.setFullScreenCoverCoordinator(nil)
                case .logoutConfirmed:
                    actionsSubject.send(.logout)
                }
            }
            .store(in: &cancellables)
        
        flowParameters.elementCallService.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                switch action {
                case .endCall:
                    self?.dismissCallScreenIfNeeded()
                default:
                    break
                }
            }
            .store(in: &cancellables)
        
        searchScreenCoordinator?.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .presentRoom(let roomID, let eventID):
                    if let eventID {
                        handleAppRoute(.event(eventID: eventID, roomID: roomID, via: []), animated: true)
                    } else {
                        handleAppRoute(.room(roomID: roomID, via: []), animated: true)
                    }
                case .cancel:
                    // Return to the tab the user came from, but never back into search.
                    navigationTabCoordinator.selectedTab = navigationTabCoordinator.previousTab == .search ? .chats : navigationTabCoordinator.previousTab ?? .chats
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Nitro Tasks
    
    private func presentNitroTaskCreate(initialRoomID: String?) {
        guard let tasksTabNavigationStackCoordinator,
              let clientProxy = userSession.clientProxy as? NitroClientProxyProtocol else {
            return
        }
        let coordinator = NitroTaskCreateScreenCoordinator(parameters: .init(taskService: clientProxy.nitroTaskService,
                                                                             draft: .init(title: "",
                                                                                          description: "",
                                                                                          fixedRoomID: nil,
                                                                                          initialRoomID: initialRoomID,
                                                                                          suggestedAssigneeID: nil,
                                                                                          origin: nil),
                                                                             userIndicatorController: flowParameters.userIndicatorController))
        coordinator.actionsPublisher
            .sink { action in
                switch action {
                case .dismiss:
                    tasksTabNavigationStackCoordinator.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        tasksTabNavigationStackCoordinator.setSheetCoordinator(coordinator)
    }
    
    private func showNitroTasks(roomID: String, roomName: String) {
        guard let tasksScreenCoordinator, let tasksTabNavigationStackCoordinator else { return }
        tasksTabNavigationStackCoordinator.setSheetCoordinator(nil)
        tasksTabNavigationStackCoordinator.popToRoot(animated: false)
        tasksScreenCoordinator.show(room: .init(id: roomID, name: roomName))
        navigationTabCoordinator.selectedTab = .tasks
    }
    
    private func presentNitroReminders() {
        guard let tasksTabNavigationStackCoordinator,
              let clientProxy = userSession.clientProxy as? NitroClientProxyProtocol,
              let reminderBaseURL = flowParameters.appSettings.nitroReminderBaseURL else {
            return
        }
        let coordinator = NitroRemindersScreenCoordinator(parameters: .init(clientProxy: clientProxy,
                                                                            reminderService: NitroReminderService(baseURL: reminderBaseURL)))
        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                tasksTabNavigationStackCoordinator.popToRoot(animated: false)
                switch action {
                case .openReminder(let roomID, let eventID, let threadRootID):
                    if let threadRootID {
                        handleAppRoute(.thread(roomID: roomID,
                                               threadRootEventID: threadRootID,
                                               focusEventID: eventID),
                                       animated: true)
                    } else {
                        handleAppRoute(.event(eventID: eventID, roomID: roomID, via: []), animated: true)
                    }
                }
            }
            .store(in: &cancellables)
        tasksTabNavigationStackCoordinator.push(coordinator)
    }
    
    private func presentNitroTaskReminder(_ task: NitroTask) async {
        guard let tasksTabNavigationStackCoordinator,
              let clientProxy = userSession.clientProxy as? NitroClientProxyProtocol,
              let reminderBaseURL = flowParameters.appSettings.nitroReminderBaseURL,
              case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(task.roomID) else {
            return
        }
        let coordinator = NitroReminderCreateScreenCoordinator(parameters: .init(eventID: task.id,
                                                                                 threadRootID: nil,
                                                                                 roomProxy: roomProxy,
                                                                                 clientProxy: clientProxy,
                                                                                 reminderService: NitroReminderService(baseURL: reminderBaseURL),
                                                                                 userIndicatorController: flowParameters.userIndicatorController))
        coordinator.actionsPublisher
            .sink { [weak tasksTabNavigationStackCoordinator] action in
                switch action {
                case .dismiss:
                    tasksTabNavigationStackCoordinator?.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        tasksTabNavigationStackCoordinator.setSheetCoordinator(coordinator)
    }
    
    private func openNitroTaskSource(_ task: NitroTask) {
        guard let roomID = task.metadata.sourceRoomID,
              let eventID = task.metadata.sourceEventID else {
            return
        }
        tasksTabNavigationStackCoordinator?.popToRoot(animated: false)
        if let threadRootID = task.metadata.sourceThreadRootID {
            handleAppRoute(.thread(roomID: roomID,
                                   threadRootEventID: threadRootID,
                                   focusEventID: eventID),
                           animated: true)
        } else {
            handleAppRoute(.event(eventID: eventID, roomID: roomID, via: []), animated: true)
        }
    }
    
    // MARK: - Onboarding
    
    private func attemptStartingOnboarding() {
        MXLog.info("Attempting to start onboarding")
        
        if onboardingFlowCoordinator.shouldStart {
            clearRoute(animated: false)
            onboardingFlowCoordinator.start()
        }
    }
    
    // MARK: - Settings
    
    private func startSettingsFlow(detached: Bool) {
        let navigationStackCoordinator = NavigationStackCoordinator()
        let coordinator = SettingsFlowCoordinator(appLockService: appLockService,
                                                  isInSecondaryWindow: detached,
                                                  navigationStackCoordinator: navigationStackCoordinator,
                                                  flowParameters: flowParameters)
        
        coordinator.actions.sink { [weak self] action in
            guard let self else { return }
            
            switch action {
            case .dismiss:
                navigationTabCoordinator.setSheetCoordinator(nil)
            case .clearCache:
                actionsSubject.send(.clearCache)
            case .runLogoutFlow:
                Task {
                    self.navigationTabCoordinator.setSheetCoordinator(nil)
                    
                    // The sheet needs to be dismissed before the alert can be shown
                    try await Task.sleep(for: .milliseconds(100))
                    await self.runLogoutFlow()
                }
            case .forceLogout:
                actionsSubject.send(.forceLogout)
            }
        }
        .store(in: &cancellables)
        
        coordinator.handleAppRoute(.settings, animated: false)
        
        if detached {
            flowParameters.windowManager.registerCoordinator(navigationStackCoordinator,
                                                             flowCoordinator: coordinator,
                                                             forWindowType: .settings)
        } else {
            settingsFlowCoordinator = coordinator
            
            navigationTabCoordinator.setSheetCoordinator(navigationStackCoordinator) { [weak self] in
                self?.stateMachine.tryEvent(.dismissedSettingsScreen)
            }
        }
    }
    
    // MARK: - Session Verification
    
    private func setupSessionVerificationRequestsObserver() {
        userSession.clientProxy.sessionVerificationController?.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self, case .receivedVerificationRequest(let details) = action else {
                    return
                }
                
                MXLog.info("Received session verification request")
                
                if details.senderProfile.id == userSession.clientProxy.userID {
                    presentSessionVerificationScreen(flow: .deviceResponder(requestDetails: details))
                } else {
                    presentSessionVerificationScreen(flow: .userResponder(requestDetails: details))
                }
            }
            .store(in: &cancellables)
    }
    
    private func presentSessionVerificationScreen(flow: SessionVerificationScreenFlow) {
        guard let sessionVerificationController = userSession.clientProxy.sessionVerificationController else {
            fatalError("The sessionVerificationController should aways be valid at this point")
        }
        
        let navigationStackCoordinator = NavigationStackCoordinator()
        
        let parameters = SessionVerificationScreenCoordinatorParameters(sessionVerificationControllerProxy: sessionVerificationController,
                                                                        flow: flow,
                                                                        appSettings: flowParameters.appSettings,
                                                                        mediaProvider: userSession.mediaProvider)
        
        let coordinator = SessionVerificationScreenCoordinator(parameters: parameters)
        
        coordinator.actions
            .sink { [weak self] action in
                switch action {
                case .done:
                    self?.navigationTabCoordinator.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        
        navigationStackCoordinator.setRootCoordinator(coordinator)
        
        navigationTabCoordinator.setSheetCoordinator(navigationStackCoordinator)
    }
    
    // MARK: - Calls
    
    private func presentCallScreen(roomID: String, isVoiceCall: Bool) async {
        guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
            return
        }
        
        presentCallScreen(roomProxy: roomProxy, voiceOnly: isVoiceCall)
    }
    
    private func presentCallScreen(roomProxy: JoinedRoomProxyProtocol, voiceOnly: Bool) {
        let colorScheme: ColorScheme = flowParameters.windowManager.mainWindow.traitCollection.userInterfaceStyle == .light ? .light : .dark
        presentCallScreen(configuration: .init(roomProxy: roomProxy,
                                               clientProxy: userSession.clientProxy,
                                               clientID: InfoPlistReader.main.bundleIdentifier,
                                               elementCallBaseURL: flowParameters.appSettings.elementCallBaseURL,
                                               elementCallBaseURLOverride: flowParameters.appSettings.elementCallBaseURLOverride,
                                               voiceOnly: voiceOnly,
                                               colorScheme: colorScheme))
    }
    
    private var callScreenPictureInPictureController: AVPictureInPictureController?
    private func presentCallScreen(configuration: ElementCallConfiguration) {
        guard flowParameters.ongoingCallRoomIDPublisher.value != configuration.callRoomID else {
            MXLog.info("Returning to existing call.")
            callScreenPictureInPictureController?.stopPictureInPicture()
            return
        }
        
        let callScreenCoordinator = CallScreenCoordinator(parameters: .init(elementCallService: flowParameters.elementCallService,
                                                                            configuration: configuration,
                                                                            allowPictureInPicture: true,
                                                                            appSettings: flowParameters.appSettings,
                                                                            analytics: flowParameters.analytics))
        
        callScreenCoordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .pictureInPictureIsAvailable(let controller):
                    callScreenPictureInPictureController = controller
                case .pictureInPictureStarted:
                    MXLog.info("Hiding call for PiP presentation.")
                    navigationTabCoordinator.setOverlayPresentationMode(.minimized)
                case .pictureInPictureStopped:
                    MXLog.info("Restoring call after PiP presentation.")
                    navigationTabCoordinator.setOverlayPresentationMode(.fullScreen)
                case .dismiss:
                    callScreenPictureInPictureController = nil
                    navigationTabCoordinator.setOverlayCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        
        navigationTabCoordinator.setOverlayCoordinator(callScreenCoordinator, animated: true)
        
        flowParameters.analytics.track(screen: .RoomCall)
    }
    
    private func hideCallScreenOverlay() {
        guard let callScreenPictureInPictureController else {
            MXLog.warning("Picture in picture isn't available, dismissing the call screen.")
            dismissCallScreenIfNeeded()
            return
        }
        
        MXLog.info("Starting picture in picture to hide the call screen overlay.")
        callScreenPictureInPictureController.startPictureInPicture()
        navigationTabCoordinator.setOverlayPresentationMode(.minimized)
    }
    
    private func dismissCallScreenIfNeeded() {
        guard navigationTabCoordinator.overlayCoordinator is CallScreenCoordinator else {
            return
        }
        
        navigationTabCoordinator.setOverlayCoordinator(nil)
    }
    
    // MARK: - Logout
    
    private func runLogoutFlow() async {
        let secureBackupController = userSession.clientProxy.secureBackupController
        
        guard case let .success(isLastDevice) = await userSession.clientProxy.isOnlyDeviceLeft() else {
            navigationRootCoordinator.alertInfo = .init(id: .init())
            return
        }
        
        guard isLastDevice else {
            navigationRootCoordinator.alertInfo = .init(id: .init(),
                                                        title: L10n.screenSignoutConfirmationDialogTitle,
                                                        message: L10n.screenSignoutConfirmationDialogContent,
                                                        primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                            self?.actionsSubject.send(.logout)
                                                        })
            return
        }
        
        guard secureBackupController.recoveryState.value == .enabled else {
            navigationRootCoordinator.alertInfo = .init(id: .init(),
                                                        title: L10n.screenSignoutRecoveryDisabledTitle,
                                                        message: L10n.screenSignoutRecoveryDisabledSubtitle,
                                                        primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                            self?.actionsSubject.send(.logout)
                                                        }, secondaryButton: .init(title: L10n.commonSettings, role: .cancel) { [weak self] in
                                                            self?.chatsTabFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                                                        })
            return
        }
        
        guard secureBackupController.keyBackupState.value == .enabled else {
            navigationRootCoordinator.alertInfo = .init(id: .init(),
                                                        title: L10n.screenSignoutKeyBackupDisabledTitle,
                                                        message: L10n.screenSignoutKeyBackupDisabledSubtitle,
                                                        primaryButton: .init(title: L10n.screenSignoutConfirmationDialogSubmit, role: .destructive) { [weak self] in
                                                            self?.actionsSubject.send(.logout)
                                                        }, secondaryButton: .init(title: L10n.commonSettings, role: .cancel) { [weak self] in
                                                            self?.chatsTabFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                                                        })
            return
        }
        
        presentSecureBackupLogoutConfirmationScreen()
    }
    
    private func presentSecureBackupLogoutConfirmationScreen() {
        let coordinator = SecureBackupLogoutConfirmationScreenCoordinator(parameters: .init(secureBackupController: userSession.clientProxy.secureBackupController,
                                                                                            homeserverReachabilityPublisher: userSession.clientProxy.homeserverReachabilityPublisher))
        
        coordinator.actions
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .cancel:
                    navigationTabCoordinator.setSheetCoordinator(nil)
                case .settings:
                    chatsTabFlowCoordinator.handleAppRoute(.chatBackupSettings, animated: true)
                    navigationTabCoordinator.setSheetCoordinator(nil)
                case .logout:
                    actionsSubject.send(.logout)
                }
            }
            .store(in: &cancellables)
        
        navigationTabCoordinator.setSheetCoordinator(coordinator, animated: true)
    }
}
