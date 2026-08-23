//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated enum NitroTaskEventParser {
    static let taskContentKey = "com.nitrovery.todo"
    static let taskUpdateContentKey = "com.nitrovery.todo.update"
    static let c2mIgnoreContentKey = "com.nitrovery.c2m.ignore"
    static let c2mStartTaskContentKey = "com.nitrovery.c2m.start_task"
    static let taskIndexEventType = "com.nitrovery.todo.index"
    static let maximumTitleLength = 500
    static let maximumDescriptionLength = 25000
    
    struct TaskEvent: Equatable, Sendable {
        let eventID: String
        let senderID: String?
        let metadata: NitroTaskMetadata
    }
    
    struct StateUpdate: Equatable, Sendable {
        let state: NitroTaskState
        let updatedDate: Date?
    }
    
    static func taskEvent(from json: String, eventIDOverride: String? = nil) -> TaskEvent? {
        guard let event = dictionary(from: json),
              event["type"] as? String == "m.room.message",
              let content = effectiveContent(in: event),
              let metadataContent = content[taskContentKey] as? [String: Any],
              let metadata = taskMetadata(from: metadataContent),
              let eventID = eventIDOverride ?? nonEmptyString(event["event_id"]) else {
            return nil
        }
        
        return TaskEvent(eventID: eventID,
                         senderID: nonEmptyString(event["sender"]),
                         metadata: metadata)
    }
    
    static func taskEvent(originalJSON: String?, latestJSON: String?, eventIDOverride: String? = nil) -> TaskEvent? {
        guard let originalJSON,
              let originalEvent = taskEvent(from: originalJSON, eventIDOverride: eventIDOverride) else {
            return latestJSON.flatMap { taskEvent(from: $0, eventIDOverride: eventIDOverride) }
        }
        guard let latestJSON,
              let latestEventDictionary = dictionary(from: latestJSON),
              latestEventDictionary["type"] as? String == "m.room.message",
              let originalSenderID = originalEvent.senderID,
              nonEmptyString(latestEventDictionary["sender"]) == originalSenderID,
              let content = latestEventDictionary["content"] as? [String: Any],
              content["m.new_content"] is [String: Any],
              let relation = content["m.relates_to"] as? [String: Any],
              relation["rel_type"] as? String == "m.replace",
              relation["event_id"] as? String == originalEvent.eventID,
              let editedEvent = taskEvent(from: latestJSON, eventIDOverride: originalEvent.eventID),
              hasSameIdentity(originalEvent.metadata, editedEvent.metadata) else {
            return originalEvent
        }
        
        return TaskEvent(eventID: originalEvent.eventID,
                         senderID: originalEvent.senderID,
                         metadata: editedEvent.metadata)
    }
    
    static func stateUpdate(from json: String, taskEventID: String) -> StateUpdate? {
        guard let event = dictionary(from: json),
              event["type"] as? String == "m.room.message",
              let content = event["content"] as? [String: Any],
              let relation = content["m.relates_to"] as? [String: Any],
              relation["rel_type"] as? String == "m.reference",
              relation["event_id"] as? String == taskEventID,
              let updateContent = content[taskUpdateContentKey] as? [String: Any],
              updateContent["version"] as? Int == 1,
              let state = taskState(from: updateContent) else {
            return nil
        }
        
        let updatedDate = finiteDouble(event["origin_server_ts"])
            .map { Date(timeIntervalSince1970: $0 / 1000) }
        return StateUpdate(state: state, updatedDate: updatedDate)
    }
    
    static func stateUpdate(originalJSON: String?, latestJSON: String?, taskEventID: String) -> StateUpdate? {
        guard let json = originalJSON ?? latestJSON else { return nil }
        return stateUpdate(from: json, taskEventID: taskEventID)
    }
    
    static func isRoomMessageEvent(_ json: String) -> Bool {
        dictionary(from: json)?["type"] as? String == "m.room.message"
    }
    
    static func mentionedUserIDs(from json: String?) -> [String] {
        guard let json,
              let event = dictionary(from: json),
              let content = effectiveContent(in: event),
              let mentions = content["m.mentions"] as? [String: Any],
              let userIDs = mentions["user_ids"] as? [Any] else {
            return []
        }
        
        var seen = Set<String>()
        return userIDs.compactMap { value in
            guard let userID = nonEmptyString(value), seen.insert(userID).inserted else { return nil }
            return userID
        }
    }
    
    static func normalizedTitle(_ value: String) -> String {
        value
            .split { $0.isWhitespace }
            .joined(separator: " ")
            .prefix(maximumTitleLength)
            .description
    }
    
    static func normalizedDescription(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maximumDescriptionLength)
            .description
    }
    
    private static func taskMetadata(from content: [String: Any]) -> NitroTaskMetadata? {
        guard content["version"] as? Int == 1,
              let title = nonEmptyString(content["title"]),
              title.count <= maximumTitleLength,
              let batchID = nonEmptyString(content["batch_id"]),
              let createdTimestamp = finiteDouble(content["created_ts"]) else {
            return nil
        }
        
        let description: String?
        if content["description"] == nil {
            description = nil
        } else if let value = nonEmptyString(content["description"]), value.count <= maximumDescriptionLength {
            description = value
        } else {
            return nil
        }
        
        let sourceRoomID = nonEmptyString(content["source_room_id"])
        let sourceEventID = nonEmptyString(content["source_event_id"])
        guard (sourceRoomID == nil) == (sourceEventID == nil) else { return nil }
        
        let sourceThreadRootID = nonEmptyString(content["source_thread_root_id"])
        let sourcePermalink = nonEmptyString(content["source_permalink"])
        guard sourceEventID != nil || (sourceThreadRootID == nil && sourcePermalink == nil) else { return nil }
        
        let initialState: NitroTaskState
        if content["initial_state"] == nil {
            initialState = .default
        } else if let value = content["initial_state"] as? [String: Any],
                  let parsedState = taskState(from: value) {
            initialState = parsedState
        } else {
            return nil
        }
        
        return NitroTaskMetadata(title: title,
                                 description: description,
                                 batchID: batchID,
                                 sourceRoomID: sourceRoomID,
                                 sourceEventID: sourceEventID,
                                 sourceThreadRootID: sourceThreadRootID,
                                 sourcePermalink: sourcePermalink,
                                 initialState: initialState,
                                 createdDate: Date(timeIntervalSince1970: createdTimestamp / 1000))
    }
    
    private static func taskState(from content: [String: Any]) -> NitroTaskState? {
        guard let rawStatus = content["status"] as? String,
              let status = NitroTaskStatus(rawValue: rawStatus),
              content.keys.contains("assignee") else {
            return nil
        }
        
        let assignee: String?
        switch content["assignee"] {
        case is NSNull:
            assignee = nil
        case let value as String where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            assignee = value
        default:
            return nil
        }
        
        return NitroTaskState(status: status, assignee: assignee)
    }
    
    private static func hasSameIdentity(_ lhs: NitroTaskMetadata, _ rhs: NitroTaskMetadata) -> Bool {
        lhs.batchID == rhs.batchID &&
            lhs.sourceRoomID == rhs.sourceRoomID &&
            lhs.sourceEventID == rhs.sourceEventID &&
            lhs.sourceThreadRootID == rhs.sourceThreadRootID &&
            lhs.sourcePermalink == rhs.sourcePermalink &&
            lhs.initialState == rhs.initialState &&
            lhs.createdDate == rhs.createdDate
    }
    
    private static func effectiveContent(in event: [String: Any]) -> [String: Any]? {
        guard let content = event["content"] as? [String: Any] else { return nil }
        return content["m.new_content"] as? [String: Any] ?? content
    }
    
    private static func dictionary(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let dictionary = value as? [String: Any] else {
            return nil
        }
        return dictionary
    }
    
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
    
    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}
