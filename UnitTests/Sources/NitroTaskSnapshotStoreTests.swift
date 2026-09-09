//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
@testable import ElementX
import Foundation
import Testing

struct NitroTaskSnapshotStoreTests {
    @Test
    func roundTripsEncryptedTaskSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskSnapshotStore(cacheDirectory: directory, passphrase: "correct horse battery staple")
        let task = makeTask()
        let taskList = NitroTaskList(tasks: [task], unavailableRoomCount: 2, pendingEventCount: 1)
        
        await store.save(taskList)
        let loaded = try #require(await store.load())
        
        #expect(loaded.unavailableRoomCount == 2)
        #expect(loaded.pendingEventCount == 0)
        let loadedTask = try #require(loaded.tasks.first)
        #expect(loadedTask.id == task.id)
        #expect(loadedTask.roomID == task.roomID)
        #expect(loadedTask.roomName == task.roomName)
        #expect(loadedTask.metadata == task.metadata)
        #expect(loadedTask.state == task.state)
        #expect(loadedTask.assigneeDisplayName == task.assigneeDisplayName)
        #expect(loadedTask.updatedDate == task.updatedDate)
        #expect(loadedTask.canUpdate)
        #expect(loadedTask.canArchive)
        #expect(loadedTask.canEditContent)
    }
    
    @Test
    func doesNotPersistTaskContentAsPlaintext() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskSnapshotStore(cacheDirectory: directory, passphrase: "test-passphrase")
        let task = makeTask()
        
        await store.save(.init(tasks: [task], unavailableRoomCount: 0))
        let fileURL = try #require(FileManager.default.contentsOfDirectory(at: directory,
                                                                           includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: fileURL)
        
        #expect(data.range(of: Data(task.metadata.title.utf8)) == nil)
        #expect(data.range(of: Data(task.metadata.description?.utf8 ?? "".utf8)) == nil)
    }
    
    @Test
    func rejectsSnapshotEncryptedWithAnotherSessionKey() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = NitroTaskSnapshotStore(cacheDirectory: directory, passphrase: "first-passphrase")
        let reader = NitroTaskSnapshotStore(cacheDirectory: directory, passphrase: "second-passphrase")
        
        await writer.save(.init(tasks: [makeTask()], unavailableRoomCount: 0))
        
        #expect(await reader.load() == nil)
    }
    
    @Test
    func rejectsLegacySnapshotWithoutCachedPermissions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let passphrase = "test-passphrase"
        let context = Data("com.nitrovery.elementx.task-snapshot-v1".utf8)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
                                         salt: context,
                                         info: context,
                                         outputByteCount: 32)
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "tasks": [],
            "unavailableRoomCount": 0,
            "pendingEventCount": 0
        ])
        let sealedBox = try AES.GCM.seal(data, using: key, authenticating: context)
        let fileURL = directory.appending(component: "nitro-task-snapshot-v1")
        try #require(sealedBox.combined).write(to: fileURL)
        let store = NitroTaskSnapshotStore(cacheDirectory: directory, passphrase: passphrase)
        
        #expect(await store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }
    
    @Test
    func doesNotRecreateDeletedSessionDirectory() async throws {
        let directory = try temporaryDirectory()
        let store = NitroTaskSnapshotStore(cacheDirectory: directory, passphrase: "test-passphrase")
        try FileManager.default.removeItem(at: directory)
        
        await store.save(.init(tasks: [makeTask()], unavailableRoomCount: 0))
        
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }
    
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(component: "nitro-task-snapshot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    
    private func makeTask() -> NitroTask {
        let state = NitroTaskState(status: .inProgress, assignee: "@alice:example.org")
        return NitroTask(id: "$task:example.org",
                         roomID: "!room:example.org",
                         roomName: "Nitro team",
                         metadata: .init(title: "Publish tajný build",
                                         description: "Ship it securely",
                                         batchID: "batch-1",
                                         sourceRoomID: "!source:example.org",
                                         sourceEventID: "$source:example.org",
                                         sourceThreadRootID: "$thread:example.org",
                                         sourcePermalink: "https://matrix.to/#/!source:example.org/$source:example.org",
                                         initialState: .default,
                                         createdDate: Date(timeIntervalSince1970: 123)),
                         state: state,
                         stateIsAvailable: true,
                         assigneeDisplayName: "Alice",
                         updatedDate: Date(timeIntervalSince1970: 456),
                         canUpdate: true,
                         canArchive: true,
                         canEditContent: true)
    }
}
