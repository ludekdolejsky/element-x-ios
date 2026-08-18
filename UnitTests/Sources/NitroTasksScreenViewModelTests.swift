//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroTasksScreenViewModelTests {
    @Test
    func matchesDesktopAssigneeColorPalette() {
        #expect(NitroTaskAssigneeColor.count == 12)
        #expect(NitroTaskAssigneeColor.index(for: "@alice:example.org") == 1)
        #expect(NitroTaskAssigneeColor.index(for: "@bob:example.org") == 6)
        #expect(NitroTaskAssigneeColor.index(for: "@😀:example.org") == 10)
    }
    
    @Test
    func loadsTasksAndUnavailableRoomCount() async throws {
        let task = makeTask()
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [task], unavailableRoomCount: 2))
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        
        #expect(viewModel.context.viewState.tasks == [task])
        #expect(viewModel.context.viewState.unavailableRoomCount == 2)
        #expect(service.loadTasksCallsCount == 1)
    }
    
    @Test
    func startsRecoveryForPendingEvents() async throws {
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [],
                                                      unavailableRoomCount: 0,
                                                      pendingEventCount: 2))
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        
        #expect(viewModel.context.viewState.pendingEventCount == 2)
        #expect(service.startPendingTaskRecoveryCallsCount == 1)
    }
    
    @Test
    func appliesRecoveredTasksAndRecoveryProgress() async throws {
        let service = NitroTaskServiceMock()
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        let task = makeTask()
        
        service.updatesSubject.send(.recoveryProgress(.init(pendingEventCount: 1, failedEventCount: 0)))
        service.updatesSubject.send(.recovered(task))
        service.updatesSubject.send(.recoveryProgress(.init(pendingEventCount: 0, failedEventCount: 1)))
        
        #expect(viewModel.context.viewState.tasks == [task])
        #expect(viewModel.context.viewState.pendingEventCount == 0)
        #expect(viewModel.context.viewState.failedEventCount == 1)
    }
    
    @Test
    func filtersTasksByRoom() async throws {
        let nitroTask = makeTask()
        let designTask = makeTask(id: "$design:example.org",
                                  roomID: "!design:example.org",
                                  roomName: "Design")
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [nitroTask, designTask], unavailableRoomCount: 0))
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        
        viewModel.context.send(viewAction: .selectRoom(designTask.roomID))
        
        #expect(viewModel.context.viewState.isFilteringByRoom)
        #expect(viewModel.context.viewState.tasks(for: .todo) == [designTask])
        #expect(viewModel.context.viewState.rooms.map(\.name) == ["Design", "Nitro team"])
    }
    
    @Test
    func keepsContextRoomFilterWithoutLoadedTasks() async throws {
        let room = NitroTaskRoom(id: "!empty:example.org", name: "Empty room")
        let service = NitroTaskServiceMock()
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        viewModel.show(room: room)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        
        #expect(viewModel.context.selectedRoomID == room.id)
        #expect(viewModel.context.viewState.rooms == [room])
        #expect(viewModel.context.viewState.tasks(for: .todo).isEmpty)
    }
    
    @Test
    func retriesPendingTaskRecovery() {
        let service = NitroTaskServiceMock()
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        
        viewModel.context.send(viewAction: .retryPendingTasks)
        
        #expect(service.startPendingTaskRecoveryCallsCount == 1)
    }
    
    @Test
    func updatesStatusAndKeepsSelectedTaskInSync() async throws {
        let task = makeTask()
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [task], unavailableRoomCount: 0))
        var updatedTask = task
        updatedTask.state.status = .inProgress
        service.updateTaskReturnValue = .success(updatedTask)
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        viewModel.context.send(viewAction: .selectTask(task))
        let updated = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0.first?.status == .inProgress }
        
        viewModel.context.send(viewAction: .setStatus(.inProgress, task: task))
        try await updated.fulfill()
        
        let arguments = try #require(service.updateTaskReceivedArguments.first)
        #expect(arguments.task == task)
        #expect(arguments.state == .init(status: .inProgress, assignee: nil))
        #expect(viewModel.context.selectedTask == updatedTask)
    }
    
    @Test
    func editsContentAndKeepsSelectedTaskInSync() async throws {
        let task = makeTask()
        var editedTask = task
        editedTask.metadata = .init(title: "Edited task",
                                    description: nil,
                                    batchID: task.metadata.batchID,
                                    sourceRoomID: task.metadata.sourceRoomID,
                                    sourceEventID: task.metadata.sourceEventID,
                                    sourceThreadRootID: task.metadata.sourceThreadRootID,
                                    sourcePermalink: task.metadata.sourcePermalink,
                                    initialState: task.metadata.initialState,
                                    createdDate: task.metadata.createdDate)
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [task], unavailableRoomCount: 0))
        service.editTaskReturnValue = .success(editedTask)
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        viewModel.context.send(viewAction: .selectTask(task))
        let updated = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [editedTask] }
        
        viewModel.context.send(viewAction: .editContent(title: " Edited task ", description: "", task: task))
        try await updated.fulfill()
        
        let arguments = try #require(service.editTaskReceivedArguments.first)
        #expect(arguments.task == task)
        #expect(arguments.title == " Edited task ")
        #expect(arguments.description.isEmpty)
        #expect(viewModel.context.selectedTask == editedTask)
    }
    
    @Test
    func createsInSelectedRoom() async throws {
        let room = NitroTaskRoom(id: "!design:example.org", name: "Design")
        let viewModel = NitroTasksScreenViewModel(taskService: NitroTaskServiceMock())
        viewModel.show(room: room)
        let create = deferFulfillment(viewModel.actionsPublisher) { action in
            guard case let .presentCreate(initialRoomID) = action else { return false }
            return initialRoomID == room.id
        }
        
        viewModel.context.send(viewAction: .showCreate)
        try await create.fulfill()
    }
    
    @Test
    func archivesTask() async throws {
        let task = makeTask()
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [task], unavailableRoomCount: 0))
        service.archiveTaskReturnValue = .success(())
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        let archived = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0.isEmpty }
        
        viewModel.context.send(viewAction: .archive(task))
        try await archived.fulfill()
        
        #expect(service.archiveTaskReceivedTasks == [task])
    }
    
    @Test
    func appliesTaskCreatedOutsideTheScreen() async throws {
        let service = NitroTaskServiceMock()
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        let task = makeTask()
        let inserted = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [task] }
        
        service.updatesSubject.send(.created(task))
        try await inserted.fulfill()
    }
    
    @Test
    func staleRefreshDoesNotRemoveRecentlyCreatedTask() async throws {
        let task = makeTask()
        let service = NitroTaskServiceMock()
        var loadCount = 0
        var staleLoadContinuation: CheckedContinuation<Result<NitroTaskList, NitroTaskServiceError>, Never>?
        let (refreshStarts, refreshStartContinuation) = AsyncStream.makeStream(of: Void.self)
        service.loadTasksClosure = {
            loadCount += 1
            if loadCount == 1 {
                return .success(.init(tasks: [], unavailableRoomCount: 0))
            }
            refreshStartContinuation.yield()
            return await withCheckedContinuation { staleLoadContinuation = $0 }
        }
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        service.updatesSubject.send(.created(task))
        
        viewModel.refresh()
        for await _ in refreshStarts {
            break
        }
        let refreshFinished = deferFulfillment(viewModel.context.observe(\.viewState.isLoading)) { !$0 }
        let continuation = try #require(staleLoadContinuation)
        continuation.resume(returning: .success(.init(tasks: [], unavailableRoomCount: 0)))
        refreshStartContinuation.finish()
        try await refreshFinished.fulfill()
        
        #expect(viewModel.context.viewState.tasks == [task])
    }
    
    @Test
    func refreshesAfterTheInitialLoad() async throws {
        let task = makeTask()
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [], unavailableRoomCount: 0))
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        service.loadTasksReturnValue = .success(.init(tasks: [task], unavailableRoomCount: 0))
        let refreshed = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [task] }
        
        viewModel.refresh()
        try await refreshed.fulfill()
        
        #expect(service.loadTasksCallsCount == 2)
    }
    
    @Test
    func queuesRefreshDuringInitialLoad() async throws {
        let task = makeTask()
        let service = NitroTaskServiceMock()
        var loadCount = 0
        var initialLoadContinuation: CheckedContinuation<Result<NitroTaskList, NitroTaskServiceError>, Never>?
        let (loadStarts, loadStartContinuation) = AsyncStream.makeStream(of: Void.self)
        service.loadTasksClosure = {
            loadCount += 1
            if loadCount == 1 {
                loadStartContinuation.yield()
                return await withCheckedContinuation { initialLoadContinuation = $0 }
            }
            return .success(.init(tasks: [task], unavailableRoomCount: 0))
        }
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        viewModel.context.send(viewAction: .load)
        for await _ in loadStarts {
            break
        }
        
        viewModel.refresh()
        let refreshed = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [task] }
        let continuation = try #require(initialLoadContinuation)
        continuation.resume(returning: .success(.init(tasks: [], unavailableRoomCount: 0)))
        loadStartContinuation.finish()
        try await refreshed.fulfill()
        
        #expect(service.loadTasksCallsCount == 2)
    }
    
    @Test
    func coalescesRefreshesWhileLoading() async throws {
        let task = makeTask()
        let service = NitroTaskServiceMock()
        var loadCount = 0
        var refreshContinuation: CheckedContinuation<Result<NitroTaskList, NitroTaskServiceError>, Never>?
        let (loadStarts, loadStartContinuation) = AsyncStream.makeStream(of: Int.self)
        service.loadTasksClosure = {
            loadCount += 1
            switch loadCount {
            case 1:
                return .success(.init(tasks: [], unavailableRoomCount: 0))
            case 2:
                loadStartContinuation.yield(loadCount)
                return await withCheckedContinuation { refreshContinuation = $0 }
            default:
                loadStartContinuation.yield(loadCount)
                return .success(.init(tasks: [task], unavailableRoomCount: 0))
            }
        }
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        viewModel.refresh()
        for await count in loadStarts where count == 2 {
            break
        }
        
        viewModel.refresh()
        viewModel.refresh()
        let refreshed = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [task] }
        let continuation = try #require(refreshContinuation)
        continuation.resume(returning: .success(.init(tasks: [], unavailableRoomCount: 0)))
        try await refreshed.fulfill()
        loadStartContinuation.finish()
        
        #expect(service.loadTasksCallsCount == 3)
    }
    
    @Test
    func refreshesAfterMutationCancelsLoad() async throws {
        let task = makeTask()
        let remoteTask = makeTask(id: "$remote:example.org")
        var updatedTask = task
        updatedTask.state.status = .inProgress
        let service = NitroTaskServiceMock()
        var loadCount = 0
        var staleLoadContinuation: CheckedContinuation<Result<NitroTaskList, NitroTaskServiceError>, Never>?
        let (refreshStarts, refreshStartContinuation) = AsyncStream.makeStream(of: Void.self)
        service.loadTasksClosure = {
            loadCount += 1
            switch loadCount {
            case 1:
                return .success(.init(tasks: [task], unavailableRoomCount: 0))
            case 2:
                refreshStartContinuation.yield()
                return await withCheckedContinuation { staleLoadContinuation = $0 }
            default:
                return .success(.init(tasks: [updatedTask, remoteTask], unavailableRoomCount: 0))
            }
        }
        service.updateTaskReturnValue = .success(updatedTask)
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        viewModel.context.send(viewAction: .refresh)
        for await _ in refreshStarts {
            break
        }
        let updated = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [updatedTask] }
        
        viewModel.context.send(viewAction: .setStatus(.inProgress, task: task))
        try await updated.fulfill()
        let remoteTaskLoaded = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { tasks in
            tasks.contains { $0.id == remoteTask.id }
        }
        let continuation = try #require(staleLoadContinuation)
        continuation.resume(returning: .success(.init(tasks: [task], unavailableRoomCount: 0)))
        refreshStartContinuation.finish()
        try await remoteTaskLoaded.fulfill()
        
        #expect(viewModel.context.viewState.tasks.contains(updatedTask))
        #expect(service.loadTasksCallsCount == 3)
    }
    
    @Test
    func queuesMutationWhileAnotherMutationIsRunning() async throws {
        let firstTask = makeTask(id: "$first:example.org")
        let secondTask = makeTask(id: "$second:example.org")
        var updatedFirstTask = firstTask
        updatedFirstTask.state.status = .inProgress
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [firstTask, secondTask], unavailableRoomCount: 0))
        var updateContinuation: CheckedContinuation<Result<NitroTask, NitroTaskServiceError>, Never>?
        let (mutationStarts, mutationStartContinuation) = AsyncStream.makeStream(of: Void.self)
        service.updateTaskClosure = { _, _ in
            mutationStartContinuation.yield()
            return await withCheckedContinuation { updateContinuation = $0 }
        }
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        viewModel.context.send(viewAction: .setStatus(.inProgress, task: firstTask))
        for await _ in mutationStarts {
            break
        }
        
        viewModel.context.send(viewAction: .archive(secondTask))
        #expect(service.archiveTaskReceivedTasks.isEmpty)
        let archived = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { tasks in
            !tasks.contains { $0.id == secondTask.id }
        }
        let continuation = try #require(updateContinuation)
        continuation.resume(returning: .success(updatedFirstTask))
        mutationStartContinuation.finish()
        try await archived.fulfill()
        
        #expect(service.archiveTaskReceivedTasks == [secondTask])
    }
    
    @Test
    func queuedContentEditUsesLatestTaskState() async throws {
        let task = makeTask()
        var stateUpdatedTask = task
        stateUpdatedTask.state.status = .inProgress
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [task], unavailableRoomCount: 0))
        var updateContinuation: CheckedContinuation<Result<NitroTask, NitroTaskServiceError>, Never>?
        let (mutationStarts, mutationStartContinuation) = AsyncStream.makeStream(of: Void.self)
        service.updateTaskClosure = { _, _ in
            mutationStartContinuation.yield()
            return await withCheckedContinuation { updateContinuation = $0 }
        }
        service.editTaskClosure = { task, title, _ in
            var editedTask = task
            editedTask.metadata = .init(title: title,
                                        description: nil,
                                        batchID: task.metadata.batchID,
                                        sourceRoomID: task.metadata.sourceRoomID,
                                        sourceEventID: task.metadata.sourceEventID,
                                        sourceThreadRootID: task.metadata.sourceThreadRootID,
                                        sourcePermalink: task.metadata.sourcePermalink,
                                        initialState: task.metadata.initialState,
                                        createdDate: task.metadata.createdDate)
            return .success(editedTask)
        }
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        viewModel.context.send(viewAction: .setStatus(.inProgress, task: task))
        for await _ in mutationStarts {
            break
        }
        viewModel.context.send(viewAction: .editContent(title: "Edited task", description: "", task: task))
        let edited = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { tasks in
            tasks.first?.metadata.title == "Edited task"
        }
        
        let continuation = try #require(updateContinuation)
        continuation.resume(returning: .success(stateUpdatedTask))
        mutationStartContinuation.finish()
        try await edited.fulfill()
        
        let arguments = try #require(service.editTaskReceivedArguments.first)
        #expect(arguments.task.status == .inProgress)
        #expect(viewModel.context.viewState.tasks.first?.status == .inProgress)
    }
    
    @Test
    func queuedAssigneeChangePreservesLatestStatus() async throws {
        let task = makeTask()
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [task], unavailableRoomCount: 0))
        var firstUpdateContinuation: CheckedContinuation<Result<NitroTask, NitroTaskServiceError>, Never>?
        let (mutationStarts, mutationStartContinuation) = AsyncStream.makeStream(of: Void.self)
        service.updateTaskClosure = { task, state in
            if firstUpdateContinuation == nil {
                mutationStartContinuation.yield()
                return await withCheckedContinuation { firstUpdateContinuation = $0 }
            }
            var updatedTask = task
            updatedTask.state = state
            return .success(updatedTask)
        }
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        viewModel.context.send(viewAction: .setStatus(.inProgress, task: task))
        for await _ in mutationStarts {
            break
        }
        viewModel.context.send(viewAction: .setAssignee("@alice:example.org", task: task))
        let updated = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { tasks in
            tasks.first?.state == .init(status: .inProgress, assignee: "@alice:example.org")
        }
        var statusUpdatedTask = task
        statusUpdatedTask.state.status = .inProgress
        let continuation = try #require(firstUpdateContinuation)
        continuation.resume(returning: .success(statusUpdatedTask))
        mutationStartContinuation.finish()
        try await updated.fulfill()
        
        let finalUpdate = try #require(service.updateTaskReceivedArguments.last)
        #expect(finalUpdate.task.status == .inProgress)
        #expect(finalUpdate.state == .init(status: .inProgress, assignee: "@alice:example.org"))
    }
    
    @Test
    func emitsNavigationActions() async throws {
        let viewModel = NitroTasksScreenViewModel(taskService: NitroTaskServiceMock())
        let create = deferFulfillment(viewModel.actionsPublisher) { action in
            if case .presentCreate = action {
                true
            } else {
                false
            }
        }
        
        viewModel.context.send(viewAction: .showCreate)
        try await create.fulfill()
    }
    
    @Test
    func presentsReminderAfterDetailsFinishDismissing() async throws {
        let task = makeTask()
        let viewModel = NitroTasksScreenViewModel(taskService: NitroTaskServiceMock())
        let reminder = deferFulfillment(viewModel.actionsPublisher) { action in
            guard case let .presentReminder(presentedTask) = action else { return false }
            return presentedTask == task
        }
        viewModel.context.send(viewAction: .selectTask(task))
        viewModel.context.send(viewAction: .remind(task))
        #expect(viewModel.context.selectedTask == nil)
        
        viewModel.context.send(viewAction: .dismissDetails)
        try await reminder.fulfill()
    }
    
    private func makeTask(id: String = "$task:example.org",
                          roomID: String = "!nitro:example.org",
                          roomName: String = "Nitro team") -> NitroTask {
        .init(id: id,
              roomID: roomID,
              roomName: roomName,
              metadata: .init(title: "Ship the iOS board",
                              description: "Keep it compatible with desktop.",
                              batchID: "batch-1",
                              sourceRoomID: "!nitro:example.org",
                              sourceEventID: "$source:example.org",
                              sourceThreadRootID: nil,
                              sourcePermalink: "https://matrix.to/#/!nitro:example.org/$source:example.org",
                              initialState: .default,
                              createdDate: Date(timeIntervalSince1970: 1_800_000_000)),
              state: .default,
              stateIsAvailable: true,
              assigneeDisplayName: nil,
              updatedDate: nil,
              canUpdate: true,
              canArchive: true,
              canEditContent: true)
    }
}
