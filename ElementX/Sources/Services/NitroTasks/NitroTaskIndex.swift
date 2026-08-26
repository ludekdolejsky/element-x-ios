//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated struct NitroTaskIndex: Equatable, Sendable {
    enum Mutation: Equatable, Sendable {
        case add(roomID: String, eventID: String)
        case remove(roomID: String, eventID: String)
        
        func targetsSameEntry(as other: Mutation) -> Bool {
            switch (self, other) {
            case (.add(let roomID, let eventID), .add(let otherRoomID, let otherEventID)),
                 (.add(let roomID, let eventID), .remove(let otherRoomID, let otherEventID)),
                 (.remove(let roomID, let eventID), .add(let otherRoomID, let otherEventID)),
                 (.remove(let roomID, let eventID), .remove(let otherRoomID, let otherEventID)):
                roomID == otherRoomID && eventID == otherEventID
            }
        }
    }
    
    struct Entry: Equatable, Hashable, Sendable {
        let roomID: String
        let eventID: String
    }
    
    struct RoomReconciliation: Equatable, Sendable {
        let roomID: String
        let retainedEventIDs: [String]
        let proposedPinRevision: String?
        let isComplete: Bool
    }
    
    static let maximumEntryCount = 5000
    
    let migrationComplete: Bool
    let tasks: [Entry]
    let roomPinRevisions: [String: String]
    
    init(migrationComplete: Bool, tasks: [Entry], roomPinRevisions: [String: String]) {
        let normalizedTasks = Self.normalize(tasks)
        self.migrationComplete = migrationComplete
        self.tasks = normalizedTasks.entries
        self.roomPinRevisions = Self.normalize(roomPinRevisions)
            .filter { !normalizedTasks.truncatedRoomIDs.contains($0.key) }
    }
    
    static func decode(_ json: String?) -> NitroTaskIndex? {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let content = object as? [String: Any],
              content["version"] as? Int == 1,
              let migrationComplete = content["migration_complete"] as? Bool,
              let rawTasks = content["tasks"] as? [Any] else {
            return nil
        }
        
        let tasks = rawTasks.compactMap { value -> Entry? in
            guard let value = value as? [String: Any],
                  let roomID = nonEmptyString(value["room_id"]),
                  let eventID = nonEmptyString(value["event_id"]) else {
                return nil
            }
            return Entry(roomID: roomID, eventID: eventID)
        }
        let revisions = (content["room_pin_revisions"] as? [String: Any] ?? [:])
            .reduce(into: [String: String]()) { result, item in
                guard !item.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let revision = nonEmptyString(item.value) else {
                    return
                }
                result[item.key] = revision
            }
        return NitroTaskIndex(migrationComplete: migrationComplete,
                              tasks: tasks,
                              roomPinRevisions: revisions)
    }
    
    func jsonString() throws -> String {
        let content: [String: Any] = [
            "version": 1,
            "migration_complete": migrationComplete,
            "tasks": tasks.map { ["room_id": $0.roomID, "event_id": $0.eventID] },
            "room_pin_revisions": roomPinRevisions
        ]
        let data = try JSONSerialization.data(withJSONObject: content)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return json
    }
    
    func eventIDs(in roomID: String) -> [String] {
        tasks.filter { $0.roomID == roomID }.map(\.eventID)
    }
    
    func adding(roomID: String, eventID: String) -> NitroTaskIndex {
        var revisions = roomPinRevisions
        revisions[roomID] = nil
        return NitroTaskIndex(migrationComplete: migrationComplete,
                              tasks: tasks + [.init(roomID: roomID, eventID: eventID)],
                              roomPinRevisions: revisions)
    }
    
    func removing(roomID: String, eventID: String) -> NitroTaskIndex? {
        let remainingTasks = tasks.filter { $0.roomID != roomID || $0.eventID != eventID }
        guard remainingTasks.count != tasks.count else { return nil }
        var revisions = roomPinRevisions
        revisions[roomID] = nil
        return NitroTaskIndex(migrationComplete: migrationComplete,
                              tasks: remainingTasks,
                              roomPinRevisions: revisions)
    }
    
    static func replaying(_ mutations: [Mutation], on index: NitroTaskIndex?) -> NitroTaskIndex? {
        mutations.reduce(index) { result, mutation in
            switch mutation {
            case .add(let roomID, let eventID):
                return (result ?? .init(migrationComplete: false, tasks: [], roomPinRevisions: [:]))
                    .adding(roomID: roomID, eventID: eventID)
            case .remove(let roomID, let eventID):
                guard let result else { return nil }
                return result.removing(roomID: roomID, eventID: eventID) ?? result
            }
        }
    }
    
    func reconciled(with latest: NitroTaskIndex?, rooms: [RoomReconciliation]) -> NitroTaskIndex {
        let activeRoomIDs = Set(rooms.map(\.roomID))
        let retainedEntries = Set(rooms.flatMap { room in
            room.retainedEventIDs.map { Entry(roomID: room.roomID, eventID: $0) }
        })
        let initialEntries = Set(tasks)
        let latestEntries = Set(latest?.tasks ?? [])
        let removedDuringReconciliation = latest == nil ? [] : initialEntries.subtracting(latestEntries)
        var entries = tasks.filter {
            activeRoomIDs.contains($0.roomID) && retainedEntries.contains($0) && !removedDuringReconciliation.contains($0)
        }
        var seenEntries = Set(entries)
        
        for entry in rooms.flatMap({ room in
            room.retainedEventIDs.map { Entry(roomID: room.roomID, eventID: $0) }
        }) where !removedDuringReconciliation.contains(entry) && seenEntries.insert(entry).inserted {
            entries.append(entry)
        }
        for entry in latest?.tasks ?? []
            where activeRoomIDs.contains(entry.roomID) && !initialEntries.contains(entry) && seenEntries.insert(entry).inserted {
            entries.append(entry)
        }
        
        var revisions = [String: String]()
        for room in rooms {
            let initialRevision = roomPinRevisions[room.roomID]
            let latestRevision = latest?.roomPinRevisions[room.roomID]
            
            if initialRevision != nil, latest != nil, latestRevision == nil {
                continue
            }
            if let latestRevision,
               latestRevision != initialRevision,
               latestRevision != room.proposedPinRevision {
                revisions[room.roomID] = latestRevision
            } else if let proposedRevision = room.proposedPinRevision {
                revisions[room.roomID] = proposedRevision
            } else if let latestRevision {
                revisions[room.roomID] = latestRevision
            }
        }
        
        return NitroTaskIndex(migrationComplete: rooms.allSatisfy(\.isComplete),
                              tasks: entries,
                              roomPinRevisions: revisions)
    }
    
    static func pinRevision(_ eventIDs: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: eventIDs),
              let revision = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return revision
    }
    
    private static func normalize(_ entries: [Entry]) -> (entries: [Entry], truncatedRoomIDs: Set<String>) {
        var seenEntries = Set<Entry>()
        let deduplicated = entries.reversed().filter { entry in
            !entry.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !entry.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                seenEntries.insert(entry).inserted
        }.reversed()
        let overflowCount = max(0, deduplicated.count - maximumEntryCount)
        let truncatedRoomIDs = Set(deduplicated.prefix(overflowCount).map(\.roomID))
        return (Array(deduplicated.dropFirst(overflowCount)), truncatedRoomIDs)
    }
    
    private static func normalize(_ revisions: [String: String]) -> [String: String] {
        let values = revisions
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .suffix(maximumEntryCount)
        return Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value) })
    }
    
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
