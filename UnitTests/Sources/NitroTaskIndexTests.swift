//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroTaskIndexTests {
    @Test
    func decodesDesktopSchemaAndNormalizesEntries() throws {
        let json = """
        {
          "version": 1,
          "migration_complete": true,
          "tasks": [
            { "room_id": "!one:example.org", "event_id": "$old" },
            { "invalid": true },
            { "room_id": "!two:example.org", "event_id": "$two" },
            { "room_id": "!one:example.org", "event_id": "$old" }
          ],
          "room_pin_revisions": {
            "!one:example.org": "old",
            "!two:example.org": "two"
          }
        }
        """
        
        let index = try #require(NitroTaskIndex.decode(json))
        
        #expect(index.migrationComplete)
        #expect(index.tasks == [
            .init(roomID: "!two:example.org", eventID: "$two"),
            .init(roomID: "!one:example.org", eventID: "$old")
        ])
        #expect(try NitroTaskIndex.decode(index.jsonString()) == index)
    }
    
    @Test
    func matchesDesktopPinRevision() {
        #expect(NitroTaskIndex.pinRevision([]) == "[]")
        #expect(NitroTaskIndex.pinRevision(["$one", "$two"]) == "[\"$one\",\"$two\"]")
    }
    
    @Test
    func addingAndRemovingEntriesInvalidatesTheRoomRevision() throws {
        let roomID = "!room:example.org"
        let initial = NitroTaskIndex(migrationComplete: true,
                                     tasks: [.init(roomID: roomID, eventID: "$one")],
                                     roomPinRevisions: [roomID: "old"])
        
        let added = initial.adding(roomID: roomID, eventID: "$two")
        #expect(added.tasks == [
            .init(roomID: roomID, eventID: "$one"),
            .init(roomID: roomID, eventID: "$two")
        ])
        #expect(added.roomPinRevisions[roomID] == nil)
        
        let removed = try #require(added.removing(roomID: roomID, eventID: "$one"))
        #expect(removed.tasks == [.init(roomID: roomID, eventID: "$two")])
        #expect(removed.roomPinRevisions[roomID] == nil)
        #expect(removed.removing(roomID: roomID, eventID: "$missing") == nil)
    }

    @Test
    func replaysLocalMutationsOverChangesFromAnotherSession() throws {
        let roomID = "!room:example.org"
        let otherRoomID = "!other:example.org"
        let remote = NitroTaskIndex(migrationComplete: true,
                                    tasks: [
                                        .init(roomID: roomID, eventID: "$remove"),
                                        .init(roomID: otherRoomID, eventID: "$desktop")
                                    ],
                                    roomPinRevisions: [roomID: "old", otherRoomID: "desktop"])

        let replayed = try #require(NitroTaskIndex.replaying([
            .add(roomID: roomID, eventID: "$ios"),
            .remove(roomID: roomID, eventID: "$remove")
        ], on: remote))

        #expect(replayed.tasks == [
            .init(roomID: otherRoomID, eventID: "$desktop"),
            .init(roomID: roomID, eventID: "$ios")
        ])
        #expect(replayed.roomPinRevisions[roomID] == nil)
        #expect(replayed.roomPinRevisions[otherRoomID] == "desktop")
    }
    
    @Test
    func reconcilesTasksAndPreservesConcurrentChanges() {
        let roomID = "!room:example.org"
        let initial = NitroTaskIndex(migrationComplete: true,
                                     tasks: [
                                         .init(roomID: roomID, eventID: "$removed"),
                                         .init(roomID: roomID, eventID: "$kept")
                                     ],
                                     roomPinRevisions: [roomID: "old"])
        let latest = NitroTaskIndex(migrationComplete: true,
                                    tasks: [
                                        .init(roomID: roomID, eventID: "$kept"),
                                        .init(roomID: roomID, eventID: "$added")
                                    ],
                                    roomPinRevisions: [:])
        
        let reconciled = initial.reconciled(with: latest,
                                            rooms: [.init(roomID: roomID,
                                                          retainedEventIDs: ["$removed", "$kept", "$scanned"],
                                                          proposedPinRevision: "new",
                                                          isComplete: true)])
        
        #expect(reconciled.tasks == [
            .init(roomID: roomID, eventID: "$kept"),
            .init(roomID: roomID, eventID: "$scanned"),
            .init(roomID: roomID, eventID: "$added")
        ])
        #expect(reconciled.roomPinRevisions[roomID] == nil)
        #expect(reconciled.migrationComplete)
    }
    
    @Test
    func incompleteReconciliationRetriesPreviousRevision() {
        let roomID = "!room:example.org"
        let initial = NitroTaskIndex(migrationComplete: true,
                                     tasks: [.init(roomID: roomID, eventID: "$task")],
                                     roomPinRevisions: [roomID: "old"])
        
        let reconciled = initial.reconciled(with: initial,
                                            rooms: [.init(roomID: roomID,
                                                          retainedEventIDs: ["$task"],
                                                          proposedPinRevision: nil,
                                                          isComplete: false)])
        
        #expect(reconciled.tasks == initial.tasks)
        #expect(reconciled.roomPinRevisions[roomID] == "old")
        #expect(!reconciled.migrationComplete)
    }
}
