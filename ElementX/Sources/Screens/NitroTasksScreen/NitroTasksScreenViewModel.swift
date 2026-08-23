//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

typealias NitroTasksScreenViewModelType = StateStoreViewModelV2<NitroTasksScreenViewState, NitroTasksScreenViewAction>

final class NitroTasksScreenViewModel: NitroTasksScreenViewModelType, NitroTasksScreenViewModelProtocol {
    private enum Mutation {
        case setStatus(NitroTaskStatus, startWithCodex: Bool)
        case setAssignee(String?)
        case editContent(title: String, description: String)
        case archive
    }
    
    private struct PendingMutation {
        let mutation: Mutation
        let task: NitroTask
    }
    
    private let taskService: NitroTaskServiceProtocol
    private var loadTask: Task<Void, Never>?
    private var loadTaskID: UUID?
    private var memberTask: Task<Void, Never>?
    private var memberTaskID: UUID?
    private var mutationTask: Task<Void, Never>?
    private var mutationTaskID: UUID?
    private var pendingMutations = [PendingMutation]()
    private var pendingCreatedTasks = [String: NitroTask]()
    private var isRefreshPending = false
    private var shouldRefreshCachedSnapshot = false
    private var dataRevision = 0
    private var pendingReminderTask: NitroTask?
    
    private let actionsSubject = PassthroughSubject<NitroTasksScreenViewModelAction, Never>()
    var actionsPublisher: AnyPublisher<NitroTasksScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(taskService: NitroTaskServiceProtocol) {
        self.taskService = taskService
        super.init(initialViewState: .init(bindings: .init()))
        
        if let cachedTaskList = taskService.cachedTaskList {
            state.tasks = cachedTaskList.tasks
            state.unavailableRoomCount = cachedTaskList.unavailableRoomCount
            state.pendingEventCount = cachedTaskList.pendingEventCount
            state.hasLoaded = true
            shouldRefreshCachedSnapshot = true
        }
        
        taskService.updatesPublisher
            .sink { [weak self] update in
                self?.apply(update)
            }
            .store(in: &cancellables)
    }
    
    override func process(viewAction: NitroTasksScreenViewAction) {
        switch viewAction {
        case .load:
            guard loadTask == nil, !state.hasLoaded || shouldRefreshCachedSnapshot else { return }
            shouldRefreshCachedSnapshot = false
            startLoad()
        case .refresh:
            requestRefresh()
        case .retryPendingTasks:
            taskService.startPendingTaskRecovery()
        case .selectStatus(let status):
            state.bindings.selectedStatus = status
        case .selectRoom(let roomID):
            guard roomID == nil || state.rooms.contains(where: { $0.id == roomID }) else { return }
            state.bindings.selectedRoomID = roomID
            if roomID == nil {
                state.filterRoomContext = nil
            } else if let room = state.rooms.first(where: { $0.id == roomID }) {
                state.filterRoomContext = room
            }
        case .selectTask(let task):
            pendingReminderTask = nil
            state.bindings.selectedTask = task
            loadMembersIfNeeded(roomID: task.roomID)
        case .dismissDetails:
            state.bindings.selectedTask = nil
            if let task = pendingReminderTask {
                pendingReminderTask = nil
                actionsSubject.send(.presentReminder(task))
            }
        case .showCreate:
            actionsSubject.send(.presentCreate(initialRoomID: state.bindings.selectedRoomID))
        case .showReminders:
            actionsSubject.send(.presentReminders)
        case .remind(let task):
            if state.bindings.selectedTask == nil {
                actionsSubject.send(.presentReminder(task))
            } else {
                pendingReminderTask = task
                state.bindings.selectedTask = nil
            }
        case .openTask(let task):
            state.bindings.selectedTask = nil
            actionsSubject.send(.openTask(task))
        case .openSource(let task):
            state.bindings.selectedTask = nil
            actionsSubject.send(.openSource(task))
        case .setStatus(let status, let task):
            startMutation(.setStatus(status, startWithCodex: false), task: task)
        case .startWithCodex(let task):
            startMutation(.setStatus(.inProgress, startWithCodex: true), task: task)
        case .setAssignee(let assigneeID, let task):
            startMutation(.setAssignee(assigneeID), task: task)
        case .editContent(let title, let description, let task):
            startMutation(.editContent(title: title, description: description), task: task)
        case .archive(let task):
            startMutation(.archive, task: task)
        }
    }
    
    func refresh() {
        guard state.hasLoaded || loadTask != nil else { return }
        requestRefresh()
    }
    
    func show(room: NitroTaskRoom) {
        state.filterRoomContext = room
        state.bindings.selectedRoomID = room.id
        if state.hasLoaded {
            requestRefresh()
        }
    }
    
    private func requestRefresh() {
        isRefreshPending = true
        startPendingRefreshIfPossible()
    }
    
    private func startPendingRefreshIfPossible() {
        guard isRefreshPending, loadTask == nil, mutationTask == nil else { return }
        isRefreshPending = false
        startLoad()
    }
    
    private func startLoad() {
        isRefreshPending = false
        loadTask?.cancel()
        state.pendingEventCount = 0
        state.failedEventCount = 0
        let taskID = UUID()
        let revision = dataRevision
        loadTaskID = taskID
        loadTask = Task { [weak self] in await self?.load(taskID: taskID, revision: revision) }
    }
    
    private func load(taskID: UUID, revision: Int) async {
        state.isLoading = true
        defer {
            if loadTaskID == taskID {
                state.isLoading = false
                state.hasLoaded = true
                loadTask = nil
                loadTaskID = nil
                startPendingRefreshIfPossible()
            }
        }
        
        switch await taskService.loadTasks() {
        case .success(let result):
            guard !Task.isCancelled, loadTaskID == taskID, dataRevision == revision else { return }
            let loadedTaskIDs = Set(result.tasks.map(\.id))
            pendingCreatedTasks = pendingCreatedTasks.filter { !loadedTaskIDs.contains($0.key) }
            state.tasks = sortedTasks(result.tasks + pendingCreatedTasks.values)
            state.unavailableRoomCount = result.unavailableRoomCount
            state.pendingEventCount = result.pendingEventCount
            state.failedEventCount = 0
            clearSelectedRoomIfNeeded()
            if let selectedTaskID = state.bindings.selectedTask?.id {
                state.bindings.selectedTask = state.tasks.first { $0.id == selectedTaskID }
            }
            if result.pendingEventCount > 0 {
                taskService.startPendingTaskRecovery()
            }
        case .failure(.cancelled):
            break
        case .failure:
            guard !Task.isCancelled, loadTaskID == taskID, dataRevision == revision else { return }
            showFailure()
        }
    }
    
    private func loadMembersIfNeeded(roomID: String) {
        guard state.membersByRoomID[roomID] == nil else { return }
        memberTask?.cancel()
        let taskID = UUID()
        memberTaskID = taskID
        memberTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if memberTaskID == taskID {
                    memberTask = nil
                    memberTaskID = nil
                }
            }
            guard case let .success(members) = await taskService.loadMembers(roomID: roomID),
                  !Task.isCancelled,
                  memberTaskID == taskID else {
                return
            }
            state.membersByRoomID[roomID] = members
        }
    }
    
    private func startMutation(_ mutation: Mutation, task: NitroTask) {
        guard mutationTask == nil else {
            pendingMutations.append(.init(mutation: mutation, task: task))
            return
        }
        invalidateLoad()
        let taskID = UUID()
        mutationTaskID = taskID
        state.busyTaskID = task.id
        mutationTask = Task { [weak self] in
            await self?.runMutation(mutation, task: task, taskID: taskID)
        }
    }
    
    private func runMutation(_ mutation: Mutation, task: NitroTask, taskID: UUID) async {
        defer { finishMutation(taskID: taskID) }
        
        switch mutation {
        case .setStatus(let status, let startWithCodex):
            var nextState = task.state
            nextState.status = status
            await updateTask(task,
                             state: nextState,
                             options: .init(startWithCodex: startWithCodex),
                             taskID: taskID)
        case .setAssignee(let assigneeID):
            var nextState = task.state
            nextState.assignee = assigneeID
            await updateTask(task, state: nextState, options: .init(), taskID: taskID)
        case .editContent(let title, let description):
            switch await taskService.editTask(task, title: title, description: description) {
            case .success(let updatedTask):
                guard !Task.isCancelled, mutationTaskID == taskID else { return }
                replaceTask(updatedTask)
            case .failure(.cancelled):
                break
            case .failure:
                guard !Task.isCancelled, mutationTaskID == taskID else { return }
                showFailure()
            }
        case .archive:
            switch await taskService.archiveTask(task) {
            case .success:
                guard !Task.isCancelled, mutationTaskID == taskID else { return }
                state.tasks.removeAll { $0.id == task.id }
                clearSelectedRoomIfNeeded()
                if state.bindings.selectedTask?.id == task.id {
                    state.bindings.selectedTask = nil
                }
            case .failure(.cancelled):
                break
            case .failure:
                guard !Task.isCancelled, mutationTaskID == taskID else { return }
                showFailure()
            }
        }
    }
    
    private func updateTask(_ task: NitroTask,
                            state nextState: NitroTaskState,
                            options: NitroTaskUpdateOptions,
                            taskID: UUID) async {
        switch await taskService.updateTask(task, state: nextState, options: options) {
        case .success(let updatedTask):
            guard !Task.isCancelled, mutationTaskID == taskID else { return }
            replaceTask(updatedTask)
        case .failure(.cancelled):
            break
        case .failure:
            guard !Task.isCancelled, mutationTaskID == taskID else { return }
            showFailure()
        }
    }
    
    private func replaceTask(_ task: NitroTask) {
        if let index = state.tasks.firstIndex(where: { $0.id == task.id }) {
            state.tasks[index] = task
        } else {
            state.tasks.append(task)
        }
        state.tasks = sortedTasks(state.tasks)
        if state.bindings.selectedTask?.id == task.id {
            state.bindings.selectedTask = task
        }
    }
    
    private func clearSelectedRoomIfNeeded() {
        guard let selectedRoomID = state.bindings.selectedRoomID,
              state.filterRoomContext?.id != selectedRoomID,
              !state.tasks.contains(where: { $0.roomID == selectedRoomID }) else {
            return
        }
        state.bindings.selectedRoomID = nil
    }
    
    private func sortedTasks<S: Sequence>(_ tasks: S) -> [NitroTask] where S.Element == NitroTask {
        tasks.sorted {
            $0.metadata.createdDate != $1.metadata.createdDate
                ? $0.metadata.createdDate > $1.metadata.createdDate
                : $0.id < $1.id
        }
    }
    
    private func finishMutation(taskID: UUID) {
        guard mutationTaskID == taskID else { return }
        mutationTask = nil
        mutationTaskID = nil
        state.busyTaskID = nil
        
        guard !pendingMutations.isEmpty else {
            startPendingRefreshIfPossible()
            return
        }
        let pendingMutation = pendingMutations.removeFirst()
        let latestTask = state.tasks.first { $0.id == pendingMutation.task.id } ?? pendingMutation.task
        startMutation(pendingMutation.mutation, task: latestTask)
    }
    
    private func invalidateLoad() {
        if loadTask != nil {
            isRefreshPending = true
        }
        dataRevision &+= 1
        loadTask?.cancel()
    }
    
    private func apply(_ update: NitroTaskServiceUpdate) {
        switch update {
        case .recovered(let task):
            guard state.hasLoaded else { return }
            replaceTask(task)
            return
        case .recoveryProgress(let progress):
            state.pendingEventCount = progress.pendingEventCount
            state.failedEventCount = progress.failedEventCount
            return
        case .created, .updated, .archived:
            break
        }
        
        switch update {
        case .created(let task):
            pendingCreatedTasks[task.id] = task
        case .updated(let task):
            if pendingCreatedTasks[task.id] != nil {
                pendingCreatedTasks[task.id] = task
            }
        case .archived(let task):
            pendingCreatedTasks.removeValue(forKey: task.id)
        case .recovered, .recoveryProgress:
            return
        }
        
        let shouldRestartInitialLoad = !state.hasLoaded && loadTask != nil
        invalidateLoad()
        
        guard state.hasLoaded else {
            if shouldRestartInitialLoad {
                startLoad()
            }
            return
        }
        
        switch update {
        case .created(let task), .updated(let task):
            replaceTask(task)
        case .archived(let task):
            state.tasks.removeAll { $0.id == task.id }
            clearSelectedRoomIfNeeded()
            if state.bindings.selectedTask?.id == task.id {
                state.bindings.selectedTask = nil
            }
        case .recovered, .recoveryProgress:
            return
        }
    }
    
    private func showFailure() {
        state.bindings.alertInfo = .init(id: .requestFailed,
                                         title: UntranslatedL10n.errorNitroTaskRequestFailedIos)
    }
}
