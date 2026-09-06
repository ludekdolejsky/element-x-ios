//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroTaskCacheMergerTests {
    @Test
    func preservesUnavailableRoomTasksAsReadOnlyDuringPartialRefresh() throws {
        let unavailableTask = makeTask(id: "$unavailable", roomID: "!unavailable")
        let unchangedTask = makeTask(id: "$unchanged", roomID: "!unchanged")
        let refreshedTask = makeTask(id: "$refreshed", roomID: "!refreshed", status: .done)
        let cachedTaskList = NitroTaskList(tasks: [unavailableTask, unchangedTask, makeTask(id: "$old", roomID: "!refreshed")],
                                           unavailableRoomCount: 0)
        
        let result = NitroTaskCacheMerger.merge(cachedTaskList: cachedTaskList,
                                                loadedTaskList: .init(tasks: [refreshedTask], unavailableRoomCount: 1),
                                                refreshedRoomIDs: ["!unavailable", "!refreshed"],
                                                unavailableRoomIDs: ["!unavailable"],
                                                pendingEventCount: 0)
        
        #expect(Set(result.tasks.map(\.id)) == ["$unavailable", "$unchanged", "$refreshed"])
        let preservedTask = try #require(result.tasks.first { $0.id == "$unavailable" })
        #expect(!preservedTask.canUpdate)
        #expect(!preservedTask.canArchive)
        #expect(!preservedTask.canEditContent)
        #expect(result.unavailableRoomCount == 1)
    }
    
    @Test
    func clearsRecoveredRoomFromUnavailableCount() {
        let refreshedTask = makeTask(id: "$refreshed", roomID: "!recovered", status: .done)
        
        let result = NitroTaskCacheMerger.merge(cachedTaskList: .init(tasks: [makeTask(id: "$old", roomID: "!recovered")],
                                                                      unavailableRoomCount: 1),
                                                loadedTaskList: .init(tasks: [refreshedTask], unavailableRoomCount: 0),
                                                refreshedRoomIDs: ["!recovered"],
                                                unavailableRoomIDs: [],
                                                pendingEventCount: 0)
        
        #expect(result.tasks == [refreshedTask])
        #expect(result.unavailableRoomCount == 0)
    }
    
    @Test
    func preservesUnavailableRoomTasksDuringFullRefresh() throws {
        let unavailableTask = makeTask(id: "$unavailable", roomID: "!unavailable")
        let refreshedTask = makeTask(id: "$refreshed", roomID: "!refreshed")
        
        let result = NitroTaskCacheMerger.merge(cachedTaskList: .init(tasks: [unavailableTask], unavailableRoomCount: 0),
                                                loadedTaskList: .init(tasks: [refreshedTask], unavailableRoomCount: 1),
                                                refreshedRoomIDs: nil,
                                                unavailableRoomIDs: ["!unavailable"],
                                                pendingEventCount: 0)
        
        #expect(Set(result.tasks.map(\.id)) == ["$unavailable", "$refreshed"])
        #expect(try !#require(result.tasks.first { $0.id == "$unavailable" }).canUpdate)
    }
    
    @Test
    func preservesCachedStateWhenLoadedStateIsUnavailable() throws {
        let cachedTask = makeTask(id: "$task", roomID: "!room", status: .done)
        let loadedTask = makeTask(id: "$task", roomID: "!room", stateIsAvailable: false)
        
        let result = NitroTaskCacheMerger.merge(cachedTaskList: .init(tasks: [cachedTask], unavailableRoomCount: 0),
                                                loadedTaskList: .init(tasks: [loadedTask], unavailableRoomCount: 0),
                                                refreshedRoomIDs: nil,
                                                unavailableRoomIDs: [],
                                                pendingEventCount: 0)
        
        let task = try #require(result.tasks.first)
        #expect(task.state.status == .done)
        #expect(!task.stateIsAvailable)
        #expect(!task.canUpdate)
        #expect(!task.canArchive)
        #expect(!task.canEditContent)
    }
    
    private func makeTask(id: String,
                          roomID: String,
                          status: NitroTaskStatus = .todo,
                          stateIsAvailable: Bool = true) -> NitroTask {
        NitroTask(id: id,
                  roomID: roomID,
                  roomName: roomID,
                  metadata: .init(title: id,
                                  description: nil,
                                  batchID: id,
                                  sourceRoomID: nil,
                                  sourceEventID: nil,
                                  sourceThreadRootID: nil,
                                  sourcePermalink: nil,
                                  initialState: .default,
                                  createdDate: Date(timeIntervalSince1970: 123)),
                  state: .init(status: status, assignee: nil),
                  stateIsAvailable: stateIsAvailable,
                  assigneeDisplayName: nil,
                  updatedDate: nil,
                  canUpdate: true,
                  canArchive: true,
                  canEditContent: true)
    }
}
