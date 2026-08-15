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
    
    var dueDate: Date {
        Date(timeIntervalSince1970: TimeInterval(dueTimestamp))
    }
    
    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdTimestamp))
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
