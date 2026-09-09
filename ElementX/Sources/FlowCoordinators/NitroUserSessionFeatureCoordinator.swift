//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Compound
import SwiftUI

enum NitroUserSessionFeatureCoordinatorAction {
    case openRoute(AppRoute)
}

final class NitroUserSessionFeatureCoordinator: CoordinatorProtocol {
    struct Parameters {
        let navigationTabCoordinator: NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>
        let userSession: UserSessionProtocol
        let reminderBaseURL: URL?
        let userIndicatorController: UserIndicatorControllerProtocol
    }
    
    private struct TasksExternalChangeSnapshot: Equatable {
        let index: NitroTaskIndexSnapshot?
    }
    
    private static let tasksExternalChangeDebounceSeconds = 1
    private static let tasksExternalChangeCheckIntervalSeconds = 30
    
    private let parameters: Parameters
    private let clientProxy: NitroClientProxyProtocol
    private let tasksScreenCoordinator: NitroTasksScreenCoordinator
    private let navigationStackCoordinator = NavigationStackCoordinator()
    private let remindersScreenCoordinator: NitroRemindersScreenCoordinator?
    private let remindersNavigationStackCoordinator: NavigationStackCoordinator?
    private let actionsSubject = PassthroughSubject<NitroUserSessionFeatureCoordinatorAction, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var tabObservationTask: Task<Void, Never>?
    private var remindersTabObservationTask: Task<Void, Never>?
    private var externalChangeCheckTask: Task<Void, Never>?
    private var reminderPresentationTask: Task<Void, Never>?
    private var externalChangeSnapshot: TasksExternalChangeSnapshot?
    private var pendingTaskRoomIDs = Set<String>()
    private var notifiedCatchUpOperationIDs = Set<String>()
    private var hasStarted = false
    
    let tabDetails: NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>.TabDetails
    let remindersTabDetails: NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>.TabDetails?
    
    var remindersTab: NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>.Tab? {
        guard let remindersNavigationStackCoordinator, let remindersTabDetails else { return nil }
        return .init(coordinator: remindersNavigationStackCoordinator, details: remindersTabDetails)
    }
    
    var actionsPublisher: AnyPublisher<NitroUserSessionFeatureCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init?(parameters: Parameters) {
        guard NitroConfiguration.isEnabled,
              let clientProxy = parameters.userSession.clientProxy as? NitroClientProxyProtocol else {
            return nil
        }
        self.parameters = parameters
        self.clientProxy = clientProxy
        tasksScreenCoordinator = NitroTasksScreenCoordinator(parameters: .init(taskService: clientProxy.nitroTaskService))
        tabDetails = .init(tag: .tasks,
                           title: UntranslatedL10n.screenNitroTasksTitleIos,
                           icon: \.checkCircle,
                           selectedIcon: \.checkCircleSolid)
        navigationStackCoordinator.setRootCoordinator(tasksScreenCoordinator)
        
        if let reminderBaseURL = parameters.reminderBaseURL {
            let remindersScreenCoordinator = NitroRemindersScreenCoordinator(parameters: .init(clientProxy: clientProxy,
                                                                                               reminderService: NitroReminderService(baseURL: reminderBaseURL),
                                                                                               previewService: NitroReminderPreviewService(clientProxy: parameters.userSession.clientProxy)))
            let remindersNavigationStackCoordinator = NavigationStackCoordinator()
            remindersNavigationStackCoordinator.setRootCoordinator(remindersScreenCoordinator)
            self.remindersScreenCoordinator = remindersScreenCoordinator
            self.remindersNavigationStackCoordinator = remindersNavigationStackCoordinator
            remindersTabDetails = .init(tag: .reminders,
                                        title: UntranslatedL10n.screenNitroRemindersTitleIos,
                                        icon: \.notifications,
                                        selectedIcon: \.notificationsSolid)
        } else {
            remindersScreenCoordinator = nil
            remindersNavigationStackCoordinator = nil
            remindersTabDetails = nil
        }
    }
    
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        setupTasksObservers()
        setupRemindersObservers()
        setupCatchUpObserver()
        setupRestoreObserver()
        clientProxy.nitroTaskService.startDirectory()
        clientProxy.nitroCatchUpService.restore()
    }
    
    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        tabObservationTask?.cancel()
        tabObservationTask = nil
        remindersTabObservationTask?.cancel()
        remindersTabObservationTask = nil
        externalChangeCheckTask?.cancel()
        externalChangeCheckTask = nil
        reminderPresentationTask?.cancel()
        reminderPresentationTask = nil
        pendingTaskRoomIDs.removeAll()
        cancellables.removeAll()
        clientProxy.nitroTaskService.stopDirectory()
        clientProxy.nitroCatchUpService.stop()
        navigationStackCoordinator.stop()
        remindersNavigationStackCoordinator?.stop()
    }
    
    isolated deinit {
        tabObservationTask?.cancel()
        remindersTabObservationTask?.cancel()
        externalChangeCheckTask?.cancel()
        reminderPresentationTask?.cancel()
    }
    
    func toPresentable() -> AnyView {
        navigationStackCoordinator.toPresentable()
    }
    
    func showTasks(roomID: String, roomName: String) {
        navigationStackCoordinator.setSheetCoordinator(nil)
        navigationStackCoordinator.popToRoot(animated: false)
        tasksScreenCoordinator.show(room: .init(id: roomID, name: roomName))
        parameters.navigationTabCoordinator.selectedTab = .tasks
    }

    func showReminders(roomID: String, roomName: String) {
        guard let remindersScreenCoordinator else { return }
        remindersNavigationStackCoordinator?.setSheetCoordinator(nil)
        remindersNavigationStackCoordinator?.popToRoot(animated: false)
        remindersScreenCoordinator.show(room: .init(id: roomID, name: roomName))
        parameters.navigationTabCoordinator.selectedTab = .reminders
    }
    
    private func setupTasksObservers() {
        tasksScreenCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .presentCreate(let initialRoomID):
                    presentTaskCreate(initialRoomID: initialRoomID)
                case .presentReminder(let task):
                    reminderPresentationTask?.cancel()
                    reminderPresentationTask = Task(name: "Present Nitro task reminder") { [weak self] in
                        await self?.presentTaskReminder(task)
                    }
                case .openTask(let task):
                    navigationStackCoordinator.popToRoot(animated: false)
                    actionsSubject.send(.openRoute(.event(eventID: task.id, roomID: task.roomID, via: [])))
                case .openSource(let task):
                    openTaskSource(task)
                }
            }
            .store(in: &cancellables)
        
        let selectedTabs = parameters.navigationTabCoordinator.observe(\.selectedTab)
        let initiallySelected = parameters.navigationTabCoordinator.selectedTab == .tasks
        tabObservationTask = Task(name: "Observe Nitro tasks tab") { [weak self] in
            var wasTasksSelected = initiallySelected
            for await selectedTab in selectedTabs {
                guard !Task.isCancelled else { return }
                let isTasksSelected = selectedTab == .tasks
                defer { wasTasksSelected = isTasksSelected }
                guard isTasksSelected, !wasTasksSelected else { continue }
                guard let self else { return }
                refreshPendingTaskChanges()
            }
        }
        
        clientProxy.nitroTaskService.changedRoomIDsPublisher
            .collect(.byTimeOrCount(DispatchQueue.main,
                                    .seconds(Self.tasksExternalChangeDebounceSeconds),
                                    100))
            .map { changes in
                changes.reduce(into: Set<String>()) { $0.formUnion($1) }
            }
            .filter { !$0.isEmpty }
            .sink { [weak self] roomIDs in
                guard let self else { return }
                if parameters.navigationTabCoordinator.selectedTab == .tasks {
                    tasksScreenCoordinator.refresh(roomIDs: roomIDs)
                } else {
                    pendingTaskRoomIDs.formUnion(roomIDs)
                }
            }
            .store(in: &cancellables)
        
        parameters.userSession.clientProxy.staticRoomSummaryProvider.roomListPublisher
            .dropFirst()
            .debounce(for: .seconds(Self.tasksExternalChangeDebounceSeconds), scheduler: DispatchQueue.main)
            .throttle(for: .seconds(Self.tasksExternalChangeCheckIntervalSeconds), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                checkForExternalTaskIndexChange()
            }
            .store(in: &cancellables)
    }
    
    private func setupCatchUpObserver() {
        clientProxy.nitroCatchUpService.operationsPublisher
            .sink { [weak self] operations in
                guard let self else { return }
                for operation in operations where !notifiedCatchUpOperationIDs.contains(operation.id) {
                    let title: String
                    let icon: KeyPath<CompoundIcons, Image>?
                    switch operation.state {
                    case .completed:
                        title = UntranslatedL10n.screenNitroCatchUpCompletedToastIos(operation.roomName)
                        icon = \.check
                    case .failed:
                        title = UntranslatedL10n.screenNitroCatchUpFailedToastIos(operation.roomName)
                        icon = \.warning
                    case .cancelled:
                        notifiedCatchUpOperationIDs.insert(operation.id)
                        continue
                    case .reading, .queued, .running:
                        continue
                    }
                    notifiedCatchUpOperationIDs.insert(operation.id)
                    parameters.userIndicatorController.submitIndicator(.init(id: "nitro-catch-up-\(operation.id)",
                                                                             title: title,
                                                                             icon: icon))
                }
            }
            .store(in: &cancellables)
    }
    
    private func setupRestoreObserver() {
        parameters.userSession.clientProxy.homeserverReachabilityPublisher
            .removeDuplicates()
            .filter { $0 == .reachable }
            .sink { [weak self] _ in
                self?.clientProxy.nitroCatchUpService.restore()
            }
            .store(in: &cancellables)
    }
    
    private func checkForExternalTaskIndexChange() {
        let taskService = clientProxy.nitroTaskService
        externalChangeCheckTask?.cancel()
        externalChangeCheckTask = Task(name: "Check external Nitro task changes") { [weak self] in
            let snapshot = await TasksExternalChangeSnapshot(index: taskService.currentTaskIndexSnapshot())
            guard !Task.isCancelled, let self else { return }
            let previousSnapshot = externalChangeSnapshot
            externalChangeSnapshot = snapshot
            guard let index = snapshot.index else { return }
            let changedEntryRoomIDs = previousSnapshot?.index.map {
                Set($0.entries.symmetricDifference(index.entries).map(\.roomID))
            } ?? []
            let roomIDs = changedEntryRoomIDs.union(index.roomIDsRequiringRefresh)
            guard !roomIDs.isEmpty else { return }
            if parameters.navigationTabCoordinator.selectedTab == .tasks {
                tasksScreenCoordinator.refresh(roomIDs: roomIDs)
            } else {
                pendingTaskRoomIDs.formUnion(roomIDs)
            }
        }
    }
    
    private func refreshPendingTaskChanges() {
        if !pendingTaskRoomIDs.isEmpty {
            let roomIDs = pendingTaskRoomIDs
            pendingTaskRoomIDs.removeAll()
            tasksScreenCoordinator.refresh(roomIDs: roomIDs)
        }
    }
    
    private func setupRemindersObservers() {
        remindersScreenCoordinator?.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                remindersNavigationStackCoordinator?.popToRoot(animated: false)
                switch action {
                case .openReminder(let roomID, let eventID, let threadRootID):
                    if let eventID, let threadRootID {
                        actionsSubject.send(.openRoute(.thread(roomID: roomID,
                                                               threadRootEventID: threadRootID,
                                                               focusEventID: eventID)))
                    } else if let eventID {
                        actionsSubject.send(.openRoute(.event(eventID: eventID, roomID: roomID, via: [])))
                    } else {
                        actionsSubject.send(.openRoute(.room(roomID: roomID, via: [])))
                    }
                }
            }
            .store(in: &cancellables)
        
        guard let remindersScreenCoordinator else { return }
        let selectedTabs = parameters.navigationTabCoordinator.observe(\.selectedTab)
        remindersTabObservationTask = Task(name: "Observe Nitro reminders tab") { [weak remindersScreenCoordinator] in
            for await selectedTab in selectedTabs {
                guard !Task.isCancelled else { return }
                guard selectedTab == .reminders else { continue }
                remindersScreenCoordinator?.refresh()
            }
        }
    }
    
    private func presentTaskCreate(initialRoomID: String?) {
        let coordinator = NitroTaskCreateScreenCoordinator(parameters: .init(taskService: clientProxy.nitroTaskService,
                                                                             draft: .init(title: "",
                                                                                          description: "",
                                                                                          fixedRoomID: nil,
                                                                                          initialRoomID: initialRoomID,
                                                                                          suggestedAssigneeID: nil,
                                                                                          origin: nil),
                                                                             userIndicatorController: parameters.userIndicatorController))
        coordinator.actionsPublisher
            .sink { [weak navigationStackCoordinator] action in
                switch action {
                case .dismiss:
                    navigationStackCoordinator?.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        navigationStackCoordinator.setSheetCoordinator(coordinator)
    }
    
    private func presentTaskReminder(_ task: NitroTask) async {
        guard let reminderBaseURL = parameters.reminderBaseURL,
              case let .joined(roomProxy) = await parameters.userSession.clientProxy.roomForIdentifier(task.roomID),
              !Task.isCancelled else {
            return
        }
        let coordinator = NitroReminderCreateScreenCoordinator(parameters: .init(eventID: task.id,
                                                                                 threadRootID: nil,
                                                                                 roomProxy: roomProxy,
                                                                                 clientProxy: clientProxy,
                                                                                 reminderService: NitroReminderService(baseURL: reminderBaseURL),
                                                                                 userIndicatorController: parameters.userIndicatorController))
        coordinator.actionsPublisher
            .sink { [weak navigationStackCoordinator] action in
                switch action {
                case .dismiss:
                    navigationStackCoordinator?.setSheetCoordinator(nil)
                }
            }
            .store(in: &cancellables)
        navigationStackCoordinator.setSheetCoordinator(coordinator)
    }
    
    private func openTaskSource(_ task: NitroTask) {
        guard let roomID = task.metadata.sourceRoomID,
              let eventID = task.metadata.sourceEventID else {
            return
        }
        navigationStackCoordinator.popToRoot(animated: false)
        if let threadRootID = task.metadata.sourceThreadRootID {
            actionsSubject.send(.openRoute(.thread(roomID: roomID,
                                                   threadRootEventID: threadRootID,
                                                   focusEventID: eventID)))
        } else {
            actionsSubject.send(.openRoute(.event(eventID: eventID, roomID: roomID, via: [])))
        }
    }
}
