//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

struct NitroTaskEventParserTests {
    @Test
    func parsesDesktopTaskMetadata() throws {
        let event = try #require(NitroTaskEventParser.taskEvent(from: Self.taskEventJSON))
        
        #expect(event.eventID == "$task:example.org")
        #expect(event.senderID == "@alice:example.org")
        #expect(event.metadata.title == "Ship the iOS board")
        #expect(event.metadata.description == "Keep it compatible with desktop.")
        #expect(event.metadata.batchID == "batch-1")
        #expect(event.metadata.sourceRoomID == "!nitro:example.org")
        #expect(event.metadata.sourceEventID == "$source:example.org")
        #expect(event.metadata.sourceThreadRootID == "$root:example.org")
        #expect(event.metadata.initialState == .init(status: .inProgress, assignee: "@bob:example.org"))
        #expect(event.metadata.createdDate == Date(timeIntervalSince1970: 1_800_000_000))
    }
    
    @Test
    func rejectsIncompleteSourceReference() {
        let json = Self.taskEventJSON.replacingOccurrences(of: "\"source_event_id\": \"$source:example.org\",", with: "")
        
        #expect(NitroTaskEventParser.taskEvent(from: json) == nil)
    }
    
    @Test
    func rejectsTitleLongerThanDesktopLimit() {
        let title = String(repeating: "a", count: NitroTaskEventParser.maximumTitleLength + 1)
        let json = Self.taskEventJSON.replacingOccurrences(of: "Ship the iOS board", with: title)
        
        #expect(NitroTaskEventParser.taskEvent(from: json) == nil)
    }
    
    @Test
    func appliesCreatorEditWithoutChangingTaskIdentity() throws {
        let event = try #require(NitroTaskEventParser.taskEvent(originalJSON: Self.taskEventJSON,
                                                                latestJSON: Self.editedTaskEventJSON(title: "Edited task")))
        
        #expect(event.eventID == "$task:example.org")
        #expect(event.senderID == "@alice:example.org")
        #expect(event.metadata.title == "Edited task")
        #expect(event.metadata.description == nil)
        #expect(event.metadata.batchID == "batch-1")
        #expect(event.metadata.initialState == .init(status: .inProgress, assignee: "@bob:example.org"))
        #expect(event.contentEventID == "$edit:example.org")
    }
    
    @Test
    func rejectsDirectoryReplacementFromAnotherRoom() throws {
        let task = try #require(NitroTaskEventParser.taskEvent(from: Self.taskEventJSON))
        let edit = Self.editedTaskEventJSON(title: "Forged")
            .replacingOccurrences(of: "\"event_id\": \"$edit:example.org\",",
                                  with: "\"event_id\": \"$edit:example.org\", \"room_id\": \"!other:example.org\",")
        
        #expect(NitroTaskEventParser.replacementTaskEvent(from: edit,
                                                          replacing: task,
                                                          roomID: "!room:example.org",
                                                          eventID: "$edit:example.org") == nil)
    }
    
    @Test
    func requiresExactDirectoryStateEventAndRelation() {
        let json = Self.stateUpdateJSON(status: "done")
        
        #expect(NitroTaskEventParser.stateUpdate(from: json,
                                                 taskEventID: "$task:example.org",
                                                 eventID: "$other:example.org") == nil)
        #expect(NitroTaskEventParser.stateUpdate(from: json,
                                                 taskEventID: "$other:example.org") == nil)
    }
    
    @Test
    func extractsOnlyOpaqueDirectoryPointer() throws {
        let pointer = try #require(NitroTaskEventParser.directoryPointer(from: Self.editedTaskEventJSON(title: "Secret title")))
        
        #expect(pointer == .content(taskEventID: "$task:example.org",
                                    eventID: "$edit:example.org",
                                    originTimestamp: 1_800_000_120_000))
    }
    
    @Test
    func ignoresEncryptedEnvelopeUntilTheEventIsLocallyDecrypted() {
        let encrypted = #"{"type":"m.room.encrypted","event_id":"$encrypted:example.org","origin_server_ts":1800000120000,"content":{"ciphertext":"secret"}}"#
        
        #expect(NitroTaskEventParser.directoryPointer(from: encrypted) == nil)
        #expect(NitroTaskDirectoryService.requiresRoomVerification(.init(events: [encrypted], limited: false, lagged: false)))
        #expect(NitroTaskEventParser.directoryPointer(from: Self.stateUpdateJSON(status: "done")) ==
            .state(taskEventID: "$task:example.org",
                   eventID: "$update:example.org",
                   originTimestamp: 1_800_000_060_000))
    }
    
    @Test
    func ignoresEditFromAnotherSender() throws {
        let edit = Self.editedTaskEventJSON(title: "Malicious edit")
            .replacingOccurrences(of: "@alice:example.org", with: "@mallory:example.org")
        let event = try #require(NitroTaskEventParser.taskEvent(originalJSON: Self.taskEventJSON,
                                                                latestJSON: edit))
        
        #expect(event.metadata.title == "Ship the iOS board")
    }
    
    @Test
    func ignoresEditThatChangesImmutableIdentity() throws {
        let edit = Self.editedTaskEventJSON(title: "Malicious edit")
            .replacingOccurrences(of: "\"batch_id\": \"batch-1\"", with: "\"batch_id\": \"different-batch\"")
        let event = try #require(NitroTaskEventParser.taskEvent(originalJSON: Self.taskEventJSON,
                                                                latestJSON: edit))
        
        #expect(event.metadata.title == "Ship the iOS board")
        #expect(event.metadata.batchID == "batch-1")
    }
    
    @Test
    func parsesLatestDesktopStateUpdate() throws {
        let update = try #require(NitroTaskEventParser.stateUpdate(from: """
        {
          "type": "m.room.message",
          "event_id": "$update:example.org",
          "origin_server_ts": 1800000060000,
          "content": {
            "m.relates_to": {
              "rel_type": "m.reference",
              "event_id": "$task:example.org"
            },
            "com.nitrovery.todo.update": {
              "version": 1,
              "status": "done",
              "assignee": null
            }
          }
        }
        """, taskEventID: "$task:example.org"))
        
        #expect(update.state == .init(status: .done, assignee: nil))
        #expect(update.updatedDate == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(update.originTimestamp == 1_800_000_060_000)
    }
    
    @Test
    func usesImmutableStateFromOriginalAuditEvent() throws {
        let originalJSON = Self.stateUpdateJSON(status: "done")
        let editedJSON = """
        {
          "type": "m.room.message",
          "content": {
            "m.relates_to": {
              "rel_type": "m.replace",
              "event_id": "$audit:example.org"
            },
            "com.nitrovery.todo.update": {
              "version": 1,
              "status": "todo",
              "assignee": null
            }
          }
        }
        """
        let update = try #require(NitroTaskEventParser.stateUpdate(originalJSON: originalJSON,
                                                                   latestJSON: editedJSON,
                                                                   taskEventID: "$task:example.org"))
        
        #expect(update.state.status == .done)
        #expect(NitroTaskEventParser.isRoomMessageEvent(originalJSON))
    }
    
    @Test
    func readsMentionsFromEditedContentWithoutDuplicates() {
        let userIDs = NitroTaskEventParser.mentionedUserIDs(from: """
        {
          "type": "m.room.message",
          "content": {
            "m.mentions": { "user_ids": ["@old:example.org"] },
            "m.new_content": {
              "m.mentions": {
                "user_ids": ["@bob:example.org", "@bob:example.org", "@carol:example.org"]
              }
            }
          }
        }
        """)
        
        #expect(userIDs == ["@bob:example.org", "@carol:example.org"])
    }
    
    private static let taskEventJSON = """
    {
      "type": "m.room.message",
      "event_id": "$task:example.org",
      "sender": "@alice:example.org",
      "content": {
        "msgtype": "m.text",
        "body": "Task: Ship the iOS board",
        "com.nitrovery.todo": {
          "version": 1,
          "title": "Ship the iOS board",
          "description": "Keep it compatible with desktop.",
          "batch_id": "batch-1",
          "source_room_id": "!nitro:example.org",
          "source_event_id": "$source:example.org",
          "source_thread_root_id": "$root:example.org",
          "source_permalink": "https://matrix.to/#/!nitro:example.org/$source:example.org",
          "initial_state": {
            "status": "in_progress",
            "assignee": "@bob:example.org"
          },
          "created_ts": 1800000000000
        }
      }
    }
    """
    
    private static func stateUpdateJSON(status: String) -> String {
        """
        {
          "type": "m.room.message",
          "event_id": "$update:example.org",
          "origin_server_ts": 1800000060000,
          "content": {
            "m.relates_to": {
              "rel_type": "m.reference",
              "event_id": "$task:example.org"
            },
            "com.nitrovery.todo.update": {
              "version": 1,
              "status": "\(status)",
              "assignee": null
            }
          }
        }
        """
    }
    
    private static func editedTaskEventJSON(title: String) -> String {
        """
        {
          "type": "m.room.message",
          "event_id": "$edit:example.org",
          "origin_server_ts": 1800000120000,
          "sender": "@alice:example.org",
          "content": {
            "msgtype": "m.text",
            "body": "* Task: \(title)",
            "m.relates_to": {
              "rel_type": "m.replace",
              "event_id": "$task:example.org"
            },
            "m.new_content": {
              "msgtype": "m.text",
              "body": "Task: \(title)",
              "com.nitrovery.todo": {
                "version": 1,
                "title": "\(title)",
                "batch_id": "batch-1",
                "source_room_id": "!nitro:example.org",
                "source_event_id": "$source:example.org",
                "source_thread_root_id": "$root:example.org",
                "source_permalink": "https://matrix.to/#/!nitro:example.org/$source:example.org",
                "initial_state": {
                  "status": "in_progress",
                  "assignee": "@bob:example.org"
                },
                "created_ts": 1800000000000
              }
            }
          }
        }
        """
    }
}

struct NitroTaskDirectoryConsistencyTests {
    @Test
    func repeatedlyStaleDirectoryLoadIsDiscarded() async throws {
        let directoryService = DirectoryLoadRaceServiceMock(currentResults: [true, false, true, false])
        let loader = NitroTaskLoader(client: ClientSDKMock(.init()),
                                     urlSession: .shared,
                                     directoryService: directoryService)
        let resolution = NitroTaskDirectoryResolution(hints: [:],
                                                      verificationRequired: [],
                                                      storeMutationTokens: [:])
        var loadCount = 0
        
        await #expect(throws: CancellationError.self) {
            _ = try await loader.loadWithConsistentDirectory(initialResolution: resolution) { _ in
                loadCount += 1
                return Self.emptyLoadedTasks
            }
        }
        #expect(loadCount == 2)
        #expect(directoryService.fallbackCount == 1)
    }
    
    private static var emptyLoadedTasks: NitroTaskService.LoadedTasks {
        .init(list: .init(tasks: [], unavailableRoomCount: 0),
              recoveryCandidates: [],
              reconciliations: [],
              unavailableRoomIDs: [],
              directoryUpdates: [],
              verifiedDirectoryKeys: [])
    }
}

private final class DirectoryLoadRaceServiceMock: NitroTaskDirectoryServiceProtocol {
    private var currentResults: [Bool]
    private(set) var fallbackCount = 0
    
    var changedRoomIDsPublisher: AnyPublisher<Set<String>, Never> {
        Empty().eraseToAnyPublisher()
    }
    
    init(currentResults: [Bool]) {
        self.currentResults = currentResults
    }
    
    func start() { }
    
    func stop() { }
    
    func resolve(_ keys: Set<NitroTaskDirectoryKey>) async -> NitroTaskDirectoryResolution {
        .init(hints: [:], verificationRequired: [], storeMutationTokens: [:])
    }
    
    func authoritativeFallbackResolution(_ resolution: NitroTaskDirectoryResolution) async -> NitroTaskDirectoryResolution {
        fallbackCount += 1
        return resolution
    }
    
    func isCurrent(_ resolution: NitroTaskDirectoryResolution) async -> Bool {
        currentResults.removeFirst()
    }
    
    func publish(_ updates: [NitroTaskDirectoryStoreUpdate],
                 clearingVerificationRequired keys: Set<NitroTaskDirectoryKey>,
                 expectedMutationTokens: [NitroTaskDirectoryKey: UInt64]) async -> Bool {
        false
    }
    
    func markVerificationRequired(_ keys: Set<NitroTaskDirectoryKey>) async { }
}
