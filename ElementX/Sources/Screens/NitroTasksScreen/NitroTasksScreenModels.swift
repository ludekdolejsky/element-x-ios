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
    var tasks = [NitroTask]() {
        didSet { updateSearchIndex() }
    }
    
    var membersByRoomID = [String: [NitroTaskMember]]()
    var isLoading = false
    var hasLoaded = false
    var busyTaskID: String?
    var unavailableRoomCount = 0
    var pendingEventCount = 0
    var failedEventCount = 0
    var filterRoomContext: NitroTaskRoom?
    var bindings: NitroTasksScreenViewStateBindings
    
    init(bindings: NitroTasksScreenViewStateBindings) {
        self.bindings = bindings
    }
    
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
    
    var isFilteringBySearch: Bool {
        !searchTerms.isEmpty
    }
    
    var filteredTasks: [NitroTask] {
        let terms = searchTerms
        return tasks.filter { task in
            guard bindings.selectedRoomID == nil || task.roomID == bindings.selectedRoomID else { return false }
            guard !terms.isEmpty else { return true }
            guard let corpus = searchIndex[task.id]?.corpus else { return false }
            return terms.allSatisfy { corpus.contains($0) }
        }
    }
    
    func tasks(for status: NitroTaskStatus) -> [NitroTask] {
        filteredTasks.filter { $0.status == status }
    }
    
    private struct SearchEntry {
        let source: SearchSource
        let corpus: String
    }
    
    private struct SearchSource: Equatable {
        let title: String
        let description: String?
        let roomName: String
        let assigneeDisplayName: String?
        let assigneeID: String?
    }
    
    private var searchIndex = [String: SearchEntry]()
    
    private var searchTerms: [String] {
        Self.normalized(bindings.searchQuery)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
    
    private mutating func updateSearchIndex() {
        let taskIDs = Set(tasks.map(\.id))
        searchIndex = searchIndex.filter { taskIDs.contains($0.key) }
        
        for task in tasks {
            let source = SearchSource(title: task.metadata.title,
                                      description: task.metadata.description,
                                      roomName: task.roomName,
                                      assigneeDisplayName: task.assigneeDisplayName,
                                      assigneeID: task.state.assignee)
            guard searchIndex[task.id]?.source != source else { continue }
            let corpus = Self.normalized([
                source.title,
                source.description,
                source.roomName,
                source.assigneeDisplayName,
                source.assigneeID
            ].compactMap { $0 }.joined(separator: " "))
            searchIndex[task.id] = .init(source: source, corpus: corpus)
        }
    }
    
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

struct NitroTasksScreenViewStateBindings {
    var selectedStatus = NitroTaskStatus.todo
    var selectedRoomID: String?
    var searchQuery = ""
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
