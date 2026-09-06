//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated enum NitroTaskCacheMerger {
    static func merge(cachedTaskList: NitroTaskList?,
                      loadedTaskList: NitroTaskList,
                      refreshedRoomIDs: Set<String>?,
                      unavailableRoomIDs: Set<String>,
                      pendingEventCount: Int) -> NitroTaskList {
        let cachedTasksByID = Dictionary(cachedTaskList?.tasks.map { ($0.id, $0) } ?? [],
                                         uniquingKeysWith: { current, _ in current })
        let loadedTasks = loadedTaskList.tasks.map { task in
            guard !task.stateIsAvailable, let cachedTask = cachedTasksByID[task.id] else { return task }
            return taskWithCachedState(task, cachedTask: cachedTask)
        }
        let loadedTaskIDs = Set(loadedTasks.map(\.id))
        let preservedTasks: [NitroTask]
        if let refreshedRoomIDs {
            let successfullyRefreshedRoomIDs = refreshedRoomIDs.subtracting(unavailableRoomIDs)
            preservedTasks = cachedTaskList?.tasks.filter { !successfullyRefreshedRoomIDs.contains($0.roomID) } ?? []
        } else {
            preservedTasks = cachedTaskList?.tasks.filter { unavailableRoomIDs.contains($0.roomID) } ?? []
        }
        
        let tasks = loadedTasks + preservedTasks
            .filter { !loadedTaskIDs.contains($0.id) }
            .map { unavailableRoomIDs.contains($0.roomID) ? readOnlyTask($0) : $0 }
        return NitroTaskList(tasks: sortedTasks(tasks),
                             unavailableRoomCount: unavailableRoomIDs.count,
                             pendingEventCount: pendingEventCount)
    }
    
    private static func readOnlyTask(_ task: NitroTask) -> NitroTask {
        NitroTask(id: task.id,
                  roomID: task.roomID,
                  roomName: task.roomName,
                  metadata: task.metadata,
                  state: task.state,
                  stateIsAvailable: task.stateIsAvailable,
                  assigneeDisplayName: task.assigneeDisplayName,
                  updatedDate: task.updatedDate,
                  canUpdate: false,
                  canArchive: false,
                  canEditContent: false)
    }
    
    private static func taskWithCachedState(_ task: NitroTask, cachedTask: NitroTask) -> NitroTask {
        NitroTask(id: task.id,
                  roomID: task.roomID,
                  roomName: task.roomName,
                  metadata: task.metadata,
                  state: cachedTask.state,
                  stateIsAvailable: false,
                  assigneeDisplayName: cachedTask.assigneeDisplayName,
                  updatedDate: cachedTask.updatedDate,
                  canUpdate: false,
                  canArchive: false,
                  canEditContent: false)
    }
    
    private static func sortedTasks(_ tasks: [NitroTask]) -> [NitroTask] {
        tasks.sorted { lhs, rhs in
            lhs.metadata.createdDate != rhs.metadata.createdDate
                ? lhs.metadata.createdDate > rhs.metadata.createdDate
                : lhs.id < rhs.id
        }
    }
}
