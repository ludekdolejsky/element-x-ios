//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated struct NitroReminderAuthentication: Sendable {
    let homeserverURL: URL
    let openIDToken: NitroOpenIDToken
}

nonisolated struct NitroReminderTarget: Equatable, Sendable {
    let roomID: String
    let roomName: String
    let eventID: String
    let threadRootID: String?
    let permalink: URL
}

nonisolated struct NitroReminderSchedule: Equatable, Sendable {
    let target: NitroReminderTarget
    let dueDate: Date
    let label: String
}

nonisolated struct NitroReminderCreation: Equatable, Sendable {
    let id: String
    let dueDate: Date
}

nonisolated enum NitroReminderFilter: String, CaseIterable, Sendable {
    case due
    case upcoming
    case done
}

nonisolated enum NitroReminderStatus: String, Decodable, Sendable {
    case pending
    case sent
    case done
    case deleted
}

nonisolated enum NitroReminderActionKind: String, Decodable, Equatable, Sendable {
    case notify
    case runCodex = "run_codex"
}

nonisolated struct NitroReminderRecurrence: Decodable, Equatable, Sendable {
    enum Kind: String, Decodable, Equatable, Sendable {
        case daily
    }
    
    let kind: Kind
    let hour: Int
    let minute: Int
    let timeZone: String
    
    private enum CodingKeys: String, CodingKey {
        case kind
        case hour
        case minute
        case timeZone = "timezone"
    }
}

nonisolated enum NitroReminderExecutionStatus: String, Decodable, Equatable, Sendable {
    case scheduled
    case claimed
    case waking
    case queued
    case retrying
    case done
    case deleted
}

nonisolated struct NitroReminder: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let userID: String
    let homeserverURL: String
    let roomID: String
    let roomName: String?
    let eventID: String
    let threadRootID: String?
    let dueTimestamp: Int
    let label: String
    let permalink: String
    let createdTimestamp: Int
    let deliveredTimestamp: Int?
    let updatedTimestamp: Int?
    let status: NitroReminderStatus
    let error: String?
    let actionKind: NitroReminderActionKind
    let prompt: String?
    let recurrence: NitroReminderRecurrence?
    let executionStatus: NitroReminderExecutionStatus?
    let lastFiredTimestamp: Int?
    
    init(id: String,
         userID: String,
         homeserverURL: String,
         roomID: String,
         roomName: String?,
         eventID: String,
         threadRootID: String?,
         dueTimestamp: Int,
         label: String,
         permalink: String,
         createdTimestamp: Int,
         deliveredTimestamp: Int?,
         updatedTimestamp: Int?,
         status: NitroReminderStatus,
         error: String?,
         actionKind: NitroReminderActionKind = .notify,
         prompt: String? = nil,
         recurrence: NitroReminderRecurrence? = nil,
         executionStatus: NitroReminderExecutionStatus? = nil,
         lastFiredTimestamp: Int? = nil) {
        self.id = id
        self.userID = userID
        self.homeserverURL = homeserverURL
        self.roomID = roomID
        self.roomName = roomName
        self.eventID = eventID
        self.threadRootID = threadRootID
        self.dueTimestamp = dueTimestamp
        self.label = label
        self.permalink = permalink
        self.createdTimestamp = createdTimestamp
        self.deliveredTimestamp = deliveredTimestamp
        self.updatedTimestamp = updatedTimestamp
        self.status = status
        self.error = error
        self.actionKind = actionKind
        self.prompt = prompt
        self.recurrence = recurrence
        self.executionStatus = executionStatus
        self.lastFiredTimestamp = lastFiredTimestamp
    }
    
    var dueDate: Date {
        Date(timeIntervalSince1970: TimeInterval(dueTimestamp))
    }
    
    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdTimestamp))
    }
    
    var lastFiredDate: Date? {
        lastFiredTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
    
    var messageEventID: String? {
        let eventID = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
        return eventID.isEmpty ? nil : eventID
    }
    
    var usesMessagePreview: Bool {
        actionKind == .notify && messageEventID != nil
    }
    
    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case homeserverURL = "homeserver_url"
        case roomID = "room_id"
        case roomName = "room_name"
        case eventID = "event_id"
        case threadRootID = "thread_root_id"
        case dueTimestamp = "due_ts"
        case label
        case permalink
        case createdTimestamp = "created_ts"
        case deliveredTimestamp = "delivered_ts"
        case updatedTimestamp = "updated_ts"
        case status
        case error
        case actionKind = "action_kind"
        case prompt
        case recurrence
        case executionStatus = "execution_status"
        case lastFiredTimestamp = "last_fired_ts"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        userID = try container.decode(String.self, forKey: .userID)
        homeserverURL = try container.decode(String.self, forKey: .homeserverURL)
        roomID = try container.decode(String.self, forKey: .roomID)
        roomName = try container.decodeIfPresent(String.self, forKey: .roomName)
        eventID = try container.decodeIfPresent(String.self, forKey: .eventID) ?? ""
        threadRootID = try container.decodeIfPresent(String.self, forKey: .threadRootID)
        dueTimestamp = try container.decode(Int.self, forKey: .dueTimestamp)
        label = try container.decode(String.self, forKey: .label)
        permalink = try container.decode(String.self, forKey: .permalink)
        createdTimestamp = try container.decode(Int.self, forKey: .createdTimestamp)
        deliveredTimestamp = try container.decodeIfPresent(Int.self, forKey: .deliveredTimestamp)
        updatedTimestamp = try container.decodeIfPresent(Int.self, forKey: .updatedTimestamp)
        status = try container.decode(NitroReminderStatus.self, forKey: .status)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        actionKind = try container.decodeIfPresent(NitroReminderActionKind.self, forKey: .actionKind) ?? .notify
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        recurrence = try container.decodeIfPresent(NitroReminderRecurrence.self, forKey: .recurrence)
        executionStatus = try container.decodeIfPresent(NitroReminderExecutionStatus.self, forKey: .executionStatus)
        lastFiredTimestamp = try container.decodeIfPresent(Int.self, forKey: .lastFiredTimestamp)
    }
}

nonisolated struct NitroReminderList: Equatable, Sendable {
    let reminders: [NitroReminder]
    let now: Date
}

nonisolated enum NitroReminderError: Error, Equatable, Sendable {
    case cancelled
    case httpError(statusCode: Int, message: String?)
    case invalidResponse
    case transport
}

// sourcery: AutoMockable
nonisolated protocol NitroReminderServiceProtocol: Sendable {
    func createReminder(_ schedule: NitroReminderSchedule,
                        authentication: NitroReminderAuthentication) async -> Result<NitroReminderCreation, NitroReminderError>
    func reminders(filter: NitroReminderFilter,
                   authentication: NitroReminderAuthentication) async -> Result<NitroReminderList, NitroReminderError>
    func markDone(reminderID: String,
                  authentication: NitroReminderAuthentication) async -> Result<NitroReminder, NitroReminderError>
    func snooze(reminderID: String,
                until dueDate: Date,
                authentication: NitroReminderAuthentication) async -> Result<NitroReminder, NitroReminderError>
    func deleteReminder(reminderID: String,
                        authentication: NitroReminderAuthentication) async -> Result<Void, NitroReminderError>
}
