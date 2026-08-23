//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NitroTasksScreenViewModelAction {
    case presentCreate(initialRoomID: String?)
    case presentReminders
    case presentReminder(NitroTask)
    case openTask(NitroTask)
    case openSource(NitroTask)
}

enum NitroTasksScreenAlertID: Hashable {
    case requestFailed
}

struct NitroTasksScreenViewState: BindableState {
    var tasks = [NitroTask]()
    var membersByRoomID = [String: [NitroTaskMember]]()
    var isLoading = false
    var hasLoaded = false
    var busyTaskID: String?
    var unavailableRoomCount = 0
    var pendingEventCount = 0
    var failedEventCount = 0
    var filterRoomContext: NitroTaskRoom?
    var bindings: NitroTasksScreenViewStateBindings
    
    var isMutating: Bool {
        busyTaskID != nil
    }
    
    var rooms: [NitroTaskRoom] {
        var seenRoomIDs = Set<String>()
        var rooms: [NitroTaskRoom] = tasks
            .compactMap { task in
                guard seenRoomIDs.insert(task.roomID).inserted else { return nil }
                return NitroTaskRoom(id: task.roomID, name: task.roomName)
            }
        if let filterRoomContext, seenRoomIDs.insert(filterRoomContext.id).inserted {
            rooms.append(filterRoomContext)
        }
        return rooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    var isFilteringByRoom: Bool {
        bindings.selectedRoomID != nil
    }
    
    func tasks(for status: NitroTaskStatus) -> [NitroTask] {
        tasks.filter { task in
            task.status == status && (bindings.selectedRoomID == nil || task.roomID == bindings.selectedRoomID)
        }
    }
}

struct NitroTasksScreenViewStateBindings {
    var selectedStatus = NitroTaskStatus.todo
    var selectedRoomID: String?
    var selectedTask: NitroTask?
    var alertInfo: AlertInfo<NitroTasksScreenAlertID>?
}

enum NitroTasksScreenViewAction {
    case load
    case refresh
    case retryPendingTasks
    case selectStatus(NitroTaskStatus)
    case selectRoom(String?)
    case selectTask(NitroTask)
    case dismissDetails
    case showCreate
    case showReminders
    case remind(NitroTask)
    case openTask(NitroTask)
    case openSource(NitroTask)
    case setStatus(NitroTaskStatus, task: NitroTask)
    case startWithCodex(NitroTask)
    case setAssignee(String?, task: NitroTask)
    case editContent(title: String, description: String, task: NitroTask)
    case archive(NitroTask)
}
