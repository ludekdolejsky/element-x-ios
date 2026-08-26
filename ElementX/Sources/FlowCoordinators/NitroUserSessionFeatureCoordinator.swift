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
        let indexRevision: String?
        let taskRoomActivity: [String: Date]
    }
    
    private static let tasksExternalChangeDebounceSeconds = 1
    private static let tasksExternalChangeCheckIntervalSeconds = 30
    
    private let parameters: Parameters
    private let clientProxy: NitroClientProxyProtocol
    private let tasksScreenCoordinator: NitroTasksScreenCoordinator
    private let navigationStackCoordinator = NavigationStackCoordinator()
    private let actionsSubject = PassthroughSubject<NitroUserSessionFeatureCoordinatorAction, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var tabObservationTask: Task<Void, Never>?
    private var externalChangeCheckTask: Task<Void, Never>?
    private var reminderPresentationTask: Task<Void, Never>?
    private var externalChangeSnapshot: TasksExternalChangeSnapshot?
    private var notifiedCatchUpOperationIDs = Set<String>()
    private var hasStarted = false
    
    let tabDetails: NavigationTabCoordinator<UserSessionFlowCoordinator.HomeTab>.TabDetails
    
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
    }
    
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        setupTasksObservers()
        setupCatchUpObserver()
        setupRestoreObserver()
        clientProxy.nitroCatchUpService.restore()
    }
    
    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        tabObservationTask?.cancel()
        tabObservationTask = nil
        externalChangeCheckTask?.cancel()
        externalChangeCheckTask = nil
        reminderPresentationTask?.cancel()
        reminderPresentationTask = nil
        cancellables.removeAll()
        clientProxy.nitroCatchUpService.stop()
        navigationStackCoordinator.stop()
    }
    
    isolated deinit {
        tabObservationTask?.cancel()
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
    
    private func setupTasksObservers() {
        tasksScreenCoordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .presentCreate(let initialRoomID):
                    presentTaskCreate(initialRoomID: initialRoomID)
                case .presentReminders:
                    presentReminders()
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
        tabObservationTask = Task(name: "Observe Nitro tasks tab") { [weak tasksScreenCoordinator] in
            for await selectedTab in selectedTabs {
                guard !Task.isCancelled else { return }
                guard selectedTab == .tasks else { continue }
                tasksScreenCoordinator?.refresh()
            }
        }
        
        parameters.userSession.clientProxy.staticRoomSummaryProvider.roomListPublisher
            .dropFirst()
            .debounce(for: .seconds(Self.tasksExternalChangeDebounceSeconds), scheduler: DispatchQueue.main)
            .throttle(for: .seconds(Self.tasksExternalChangeCheckIntervalSeconds), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] rooms in
                guard let self, parameters.navigationTabCoordinator.selectedTab == .tasks else { return }
                checkForExternalTaskChanges(in: rooms)
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
    
    private func checkForExternalTaskChanges(in rooms: [RoomSummary]) {
        let taskService = clientProxy.nitroTaskService
        let taskRoomIDs = Set(taskService.cachedTaskList?.tasks.map(\.roomID) ?? [])
        let taskRoomActivity = rooms.reduce(into: [String: Date]()) { result, room in
            guard taskRoomIDs.contains(room.id) else { return }
            result[room.id] = room.lastMessageDate ?? .distantPast
        }
        
        externalChangeCheckTask?.cancel()
        externalChangeCheckTask = Task(name: "Check external Nitro task changes") { [weak self] in
            let snapshot = await TasksExternalChangeSnapshot(indexRevision: taskService.currentTaskIndexRevision(),
                                                             taskRoomActivity: taskRoomActivity)
            guard !Task.isCancelled, let self else { return }
            let previousSnapshot = externalChangeSnapshot
            externalChangeSnapshot = snapshot
            guard previousSnapshot == nil || previousSnapshot != snapshot else { return }
            tasksScreenCoordinator.refresh()
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
    
    private func presentReminders() {
        guard let reminderBaseURL = parameters.reminderBaseURL else { return }
        let coordinator = NitroRemindersScreenCoordinator(parameters: .init(clientProxy: clientProxy,
                                                                            reminderService: NitroReminderService(baseURL: reminderBaseURL)))
        coordinator.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                navigationStackCoordinator.popToRoot(animated: false)
                switch action {
                case .openReminder(let roomID, let eventID, let threadRootID):
                    if let threadRootID {
                        actionsSubject.send(.openRoute(.thread(roomID: roomID,
                                                               threadRootEventID: threadRootID,
                                                               focusEventID: eventID)))
                    } else {
                        actionsSubject.send(.openRoute(.event(eventID: eventID, roomID: roomID, via: [])))
                    }
                }
            }
            .store(in: &cancellables)
        navigationStackCoordinator.push(coordinator)
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
