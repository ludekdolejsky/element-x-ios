//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated enum NitroTaskStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case todo
    case inProgress = "in_progress"
    case done
    
    var id: Self {
        self
    }
}

nonisolated struct NitroTaskState: Codable, Equatable, Sendable {
    var status: NitroTaskStatus
    var assignee: String?
    
    static let `default` = NitroTaskState(status: .todo, assignee: nil)
}

nonisolated struct NitroTaskMetadata: Equatable, Sendable {
    let title: String
    let description: String?
    let batchID: String
    let sourceRoomID: String?
    let sourceEventID: String?
    let sourceThreadRootID: String?
    let sourcePermalink: String?
    let initialState: NitroTaskState
    let createdDate: Date
}

nonisolated struct NitroTaskOrigin: Equatable, Sendable {
    let roomID: String
    let eventID: String
    let threadRootID: String?
    let permalink: String?
}

nonisolated struct NitroTask: Equatable, Identifiable, Sendable {
    let id: String
    let roomID: String
    let roomName: String
    var metadata: NitroTaskMetadata
    var state: NitroTaskState
    var stateIsAvailable: Bool
    var assigneeDisplayName: String?
    var updatedDate: Date?
    let canUpdate: Bool
    let canArchive: Bool
    var canEditContent = false
    
    var status: NitroTaskStatus {
        state.status
    }
    
    var sourceText: String? {
        metadata.description
    }
}

nonisolated struct NitroTaskRoom: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

nonisolated struct NitroTaskMember: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String?
    let avatarURL: URL?
    
    var title: String {
        guard let displayName, !displayName.isEmpty, displayName != id else { return id }
        return displayName
    }
}

nonisolated struct NitroTaskCreationRequest: Equatable, Sendable {
    let roomID: String
    let title: String
    let description: String?
    let assigneeID: String?
    let origin: NitroTaskOrigin?
}

nonisolated struct NitroTaskCreateDraft: Equatable, Sendable {
    let title: String
    let description: String
    let fixedRoomID: String?
    let initialRoomID: String?
    let suggestedAssigneeID: String?
    let origin: NitroTaskOrigin?
    
    static let empty = NitroTaskCreateDraft(title: "",
                                            description: "",
                                            fixedRoomID: nil,
                                            initialRoomID: nil,
                                            suggestedAssigneeID: nil,
                                            origin: nil)
}

nonisolated struct NitroTaskList: Equatable, Sendable {
    let tasks: [NitroTask]
    let unavailableRoomCount: Int
    let pendingEventCount: Int
    
    init(tasks: [NitroTask], unavailableRoomCount: Int, pendingEventCount: Int = 0) {
        self.tasks = tasks
        self.unavailableRoomCount = unavailableRoomCount
        self.pendingEventCount = pendingEventCount
    }
}

nonisolated struct NitroTaskRecoveryProgress: Equatable, Sendable {
    let pendingEventCount: Int
    let failedEventCount: Int
}

nonisolated enum NitroTaskServiceUpdate: Equatable, Sendable {
    case created(NitroTask)
    case updated(NitroTask)
    case archived(NitroTask)
    case recovered(NitroTask)
    case recoveryProgress(NitroTaskRecoveryProgress)
}

nonisolated enum NitroTaskServiceError: Error, Equatable, Sendable {
    case cancelled
    case invalidTask
    case invalidResponse
    case roomUnavailable
    case permissionDenied
    case stateUnavailable
    case requestFailed
    case sendFailed
}
