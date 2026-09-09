//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroTasksScreenCacheTests {
    @Test
    func loadsPersistentSnapshotWithoutNetworkHydration() async throws {
        let cachedTask = makeTask()
        let service = NitroTaskServiceMock()
        service.loadCachedTasksReturnValue = .init(tasks: [cachedTask], unavailableRoomCount: 1)
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let hydrated = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [cachedTask] }
        
        viewModel.context.send(viewAction: .load)
        try await hydrated.fulfill()
        
        #expect(viewModel.context.viewState.hasLoaded)
        #expect(!viewModel.context.viewState.isLoading)
        #expect(viewModel.context.viewState.canMutateTasks)
        #expect(service.loadCachedTasksCallsCount == 1)
        #expect(service.loadTasksCallsCount == 0)
    }
    
    @Test
    func inMemorySnapshotDoesNotRefreshWhenViewLoads() {
        let cachedTask = makeTask()
        let service = NitroTaskServiceMock()
        service.cachedTaskList = .init(tasks: [cachedTask], unavailableRoomCount: 0)
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        
        viewModel.context.send(viewAction: .load)
        
        #expect(viewModel.context.viewState.tasks == [cachedTask])
        #expect(!viewModel.context.viewState.isLoading)
        #expect(service.loadCachedTasksCallsCount == 0)
        #expect(service.loadTasksCallsCount == 0)
    }
    
    @Test
    func refreshesOnlyChangedRooms() async throws {
        let task = makeTask()
        let updatedTask = makeTask(state: .init(status: .done, assignee: nil))
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [task], unavailableRoomCount: 0))
        service.refreshTasksReturnValue = .success(.init(tasks: [updatedTask], unavailableRoomCount: 0))
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        let refreshed = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [updatedTask] }
        
        viewModel.refresh(roomIDs: [task.roomID])
        try await refreshed.fulfill()
        
        #expect(service.refreshTasksReceivedRoomIDs == [[task.roomID]])
        #expect(service.loadTasksCallsCount == 1)
    }
    
    @Test
    func roomEntryRefreshesOnlyThatRoom() async {
        let task = makeTask()
        let service = NitroTaskServiceMock()
        service.cachedTaskList = .init(tasks: [task], unavailableRoomCount: 0)
        let (refreshes, continuation) = AsyncStream.makeStream(of: Set<String>.self)
        service.refreshTasksClosure = { roomIDs in
            continuation.yield(roomIDs)
            return .success(.init(tasks: [task], unavailableRoomCount: 0))
        }
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        
        viewModel.show(room: .init(id: task.roomID, name: task.roomName))
        for await roomIDs in refreshes {
            #expect(roomIDs == [task.roomID])
            break
        }
        continuation.finish()
        
        #expect(service.refreshTasksReceivedRoomIDs == [[task.roomID]])
        #expect(service.loadTasksCallsCount == 0)
    }
    
    @Test
    func persistedRoomChangeWaitsForSnapshotHydration() async {
        let task = makeTask()
        let service = NitroTaskServiceMock()
        service.loadCachedTasksReturnValue = .init(tasks: [task], unavailableRoomCount: 0)
        let (refreshes, continuation) = AsyncStream.makeStream(of: Set<String>.self)
        service.refreshTasksClosure = { roomIDs in
            continuation.yield(roomIDs)
            return .success(.init(tasks: [task], unavailableRoomCount: 0))
        }
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        
        viewModel.refresh(roomIDs: [task.roomID])
        viewModel.context.send(viewAction: .load)
        for await roomIDs in refreshes {
            #expect(roomIDs == [task.roomID])
            break
        }
        continuation.finish()
        
        #expect(service.loadCachedTasksCallsCount == 1)
        #expect(service.refreshTasksReceivedRoomIDs == [[task.roomID]])
        #expect(service.loadTasksCallsCount == 0)
    }
    
    @Test
    func offlineTaskIndexChangeRefreshesOnlyChangedRooms() async {
        let task = makeTask()
        let addedKey = NitroTaskDirectoryKey(roomID: "!new:example.org", taskEventID: "$new:example.org")
        let service = NitroTaskServiceMock()
        service.loadCachedTasksReturnValue = .init(tasks: [task], unavailableRoomCount: 0)
        service.currentTaskIndexSnapshotReturnValue = .init(entries: [
            .init(roomID: task.roomID, taskEventID: task.id),
            addedKey
        ], roomIDsRequiringRefresh: [])
        let (refreshes, continuation) = AsyncStream.makeStream(of: Set<String>.self)
        service.refreshTasksClosure = { roomIDs in
            continuation.yield(roomIDs)
            return .success(.init(tasks: [task], unavailableRoomCount: 0))
        }
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        
        viewModel.context.send(viewAction: .load)
        for await roomIDs in refreshes {
            #expect(roomIDs == [addedKey.roomID])
            break
        }
        continuation.finish()
        
        #expect(service.currentTaskIndexSnapshotCallsCount == 1)
        #expect(service.refreshTasksReceivedRoomIDs == [[addedKey.roomID]])
        #expect(service.loadTasksCallsCount == 0)
    }
    
    @Test
    func changedPinRevisionRefreshesOnlyThatRoom() async {
        let task = makeTask()
        let changedRoomID = "!changed:example.org"
        let service = NitroTaskServiceMock()
        service.loadCachedTasksReturnValue = .init(tasks: [task], unavailableRoomCount: 0)
        service.currentTaskIndexSnapshotReturnValue = .init(entries: [
            .init(roomID: task.roomID, taskEventID: task.id)
        ], roomIDsRequiringRefresh: [changedRoomID])
        let (refreshes, continuation) = AsyncStream.makeStream(of: Set<String>.self)
        service.refreshTasksClosure = { roomIDs in
            continuation.yield(roomIDs)
            return .success(.init(tasks: [task], unavailableRoomCount: 0))
        }
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        
        viewModel.context.send(viewAction: .load)
        for await roomIDs in refreshes {
            #expect(roomIDs == [changedRoomID])
            break
        }
        continuation.finish()
        
        #expect(service.refreshTasksReceivedRoomIDs == [[changedRoomID]])
        #expect(service.loadTasksCallsCount == 0)
    }
    
    @Test
    func restartsPendingRecoveryWhenRefreshFails() async throws {
        let task = makeTask()
        let service = NitroTaskServiceMock()
        service.loadTasksReturnValue = .success(.init(tasks: [task], unavailableRoomCount: 0))
        service.refreshTasksReturnValue = .failure(.requestFailed)
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        let failed = deferFulfillment(viewModel.context.observe(\.viewState.bindings.alertInfo)) { $0?.id == .requestFailed }
        
        viewModel.refresh(roomIDs: [task.roomID])
        try await failed.fulfill()
        
        #expect(service.startPendingTaskRecoveryCallsCount == 1)
    }
    
    private func makeTask(id: String = "$task:example.org",
                          state: NitroTaskState = .default) -> NitroTask {
        NitroTask(id: id,
                  roomID: "!room:example.org",
                  roomName: "Nitro team",
                  metadata: .init(title: "Publish build",
                                  description: "Ship it",
                                  batchID: "batch-1",
                                  sourceRoomID: nil,
                                  sourceEventID: nil,
                                  sourceThreadRootID: nil,
                                  sourcePermalink: nil,
                                  initialState: .default,
                                  createdDate: Date(timeIntervalSince1970: 123)),
                  state: state,
                  stateIsAvailable: true,
                  assigneeDisplayName: nil,
                  updatedDate: nil,
                  canUpdate: true,
                  canArchive: true,
                  canEditContent: true)
    }
}
