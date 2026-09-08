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
    func hydratesPersistentSnapshotBeforeNetworkRefresh() async throws {
        let cachedTask = makeTask()
        let refreshedTask = makeTask(id: "$fresh:example.org")
        let service = NitroTaskServiceMock()
        service.loadCachedTasksReturnValue = .init(tasks: [cachedTask], unavailableRoomCount: 1)
        let (networkResults, networkContinuation) = AsyncStream.makeStream(of: Result<NitroTaskList, NitroTaskServiceError>.self)
        service.refreshKnownTasksClosure = {
            for await result in networkResults {
                return result
            }
            return .failure(.cancelled)
        }
        service.loadTasksReturnValue = .success(.init(tasks: [refreshedTask], unavailableRoomCount: 0))
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let hydrated = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [cachedTask] }
        
        viewModel.context.send(viewAction: .load)
        try await hydrated.fulfill()
        
        #expect(viewModel.context.viewState.hasLoaded)
        #expect(viewModel.context.viewState.isLoading)
        #expect(service.loadCachedTasksCallsCount == 1)
        viewModel.context.send(viewAction: .setStatus(.done, task: cachedTask))
        #expect(service.updateTaskReceivedArguments.isEmpty)
        
        let refreshed = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [refreshedTask] }
        networkContinuation.yield(.success(.init(tasks: [refreshedTask], unavailableRoomCount: 0)))
        networkContinuation.finish()
        try await refreshed.fulfill()
        #expect(!viewModel.context.viewState.isLoading)
        #expect(service.refreshKnownTasksCallsCount == 1)
    }
    
    @Test
    func finishesVisibleRefreshBeforeBackgroundDiscovery() async throws {
        let cachedTask = makeTask()
        let refreshedTask = makeTask(id: "$fresh:example.org")
        let discoveredTask = makeTask(id: "$discovered:example.org")
        let service = NitroTaskServiceMock()
        service.cachedTaskList = .init(tasks: [cachedTask], unavailableRoomCount: 0)
        service.refreshKnownTasksReturnValue = .success(.init(tasks: [refreshedTask], unavailableRoomCount: 0))
        let (discoveryResults, discoveryContinuation) = AsyncStream.makeStream(of: Result<NitroTaskList, NitroTaskServiceError>.self)
        let (discoveryStarts, discoveryStartContinuation) = AsyncStream.makeStream(of: Void.self)
        service.loadTasksClosure = {
            discoveryStartContinuation.yield()
            for await result in discoveryResults {
                return result
            }
            return .failure(.cancelled)
        }
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let refreshed = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [refreshedTask] }
        
        viewModel.context.send(viewAction: .load)
        try await refreshed.fulfill()
        for await _ in discoveryStarts {
            break
        }
        
        #expect(!viewModel.context.viewState.isLoading)
        #expect(service.refreshKnownTasksCallsCount == 1)
        #expect(service.loadTasksCallsCount == 1)
        
        let discovered = deferFulfillment(viewModel.context.observe(\.viewState.tasks)) { $0 == [discoveredTask] }
        discoveryContinuation.yield(.success(.init(tasks: [discoveredTask], unavailableRoomCount: 0)))
        discoveryContinuation.finish()
        discoveryStartContinuation.finish()
        try await discovered.fulfill()
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
