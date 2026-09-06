//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

nonisolated protocol NitroTaskSnapshotStoreProtocol: Sendable {
    func load() async -> NitroTaskList?
    func save(_ taskList: NitroTaskList) async
}

actor NitroTaskSnapshotStore: NitroTaskSnapshotStoreProtocol {
    fileprivate nonisolated struct Snapshot: Codable, Sendable {
        static let currentVersion = 1
        let version: Int
        let tasks: [TaskSnapshot]
        let unavailableRoomCount: Int
        let pendingEventCount: Int
    }
    
    fileprivate nonisolated struct TaskSnapshot: Codable, Sendable {
        let id: String
        let roomID: String
        let roomName: String
        let metadata: Metadata
        let state: State
        let stateIsAvailable: Bool
        let assigneeDisplayName: String?
        let updatedDate: Date?
    }
    
    fileprivate nonisolated struct Metadata: Codable, Sendable {
        let title: String
        let description: String?
        let batchID: String
        let sourceRoomID: String?
        let sourceEventID: String?
        let sourceThreadRootID: String?
        let sourcePermalink: String?
        let initialState: State
        let createdDate: Date
    }
    
    fileprivate nonisolated struct State: Codable, Sendable {
        let status: NitroTaskStatus
        let assignee: String?
    }
    
    private static let fileName = "nitro-task-snapshot-v1"
    private static let keyContext = Data("com.nitrovery.elementx.task-snapshot-v1".utf8)
    private static let maximumPayloadSize = 16 * 1024 * 1024
    private let fileURL: URL
    private let key: SymmetricKey
    
    init(cacheDirectory: URL, passphrase: String) {
        fileURL = cacheDirectory.appending(component: Self.fileName)
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
                                     salt: Self.keyContext,
                                     info: Self.keyContext,
                                     outputByteCount: 32)
    }
    
    func load() async -> NitroTaskList? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        do {
            let encryptedData = try Data(contentsOf: fileURL)
            guard encryptedData.count <= Self.maximumPayloadSize + 1024 else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            let data = try AES.GCM.open(sealedBox, using: key, authenticating: Self.keyContext)
            guard data.count <= Self.maximumPayloadSize else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard snapshot.version == Snapshot.currentVersion,
                  snapshot.tasks.count <= NitroTaskIndex.maximumEntryCount else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            return snapshot.taskList
        } catch {
            MXLog.info("Ignoring an invalid Nitro task snapshot: \(error)")
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }
    
    func save(_ taskList: NitroTaskList) async {
        guard !Task.isCancelled else { return }
        do {
            guard FileManager.default.directoryExists(at: fileURL.deletingLastPathComponent()) else { return }
            let snapshot = Snapshot(taskList)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(snapshot)
            guard data.count <= Self.maximumPayloadSize else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            let sealedBox = try AES.GCM.seal(data, using: key, authenticating: Self.keyContext)
            guard let encryptedData = sealedBox.combined else { return }
            try encryptedData.write(to: fileURL,
                                    options: [Data.WritingOptions.atomic,
                                              Data.WritingOptions.completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            MXLog.error("Failed saving the Nitro task snapshot: \(error)")
        }
    }
}

private nonisolated extension NitroTaskSnapshotStore.Snapshot {
    init(_ taskList: NitroTaskList) {
        version = Self.currentVersion
        tasks = taskList.tasks.map(NitroTaskSnapshotStore.TaskSnapshot.init)
        unavailableRoomCount = taskList.unavailableRoomCount
        pendingEventCount = 0
    }
    
    var taskList: NitroTaskList {
        NitroTaskList(tasks: tasks.map(\.task),
                      unavailableRoomCount: unavailableRoomCount,
                      pendingEventCount: 0)
    }
}

private nonisolated extension NitroTaskSnapshotStore.TaskSnapshot {
    init(_ task: NitroTask) {
        id = task.id
        roomID = task.roomID
        roomName = task.roomName
        metadata = .init(task.metadata)
        state = .init(task.state)
        stateIsAvailable = task.stateIsAvailable
        assigneeDisplayName = task.assigneeDisplayName
        updatedDate = task.updatedDate
    }
    
    var task: NitroTask {
        NitroTask(id: id,
                  roomID: roomID,
                  roomName: roomName,
                  metadata: metadata.metadata,
                  state: state.state,
                  stateIsAvailable: stateIsAvailable,
                  assigneeDisplayName: assigneeDisplayName,
                  updatedDate: updatedDate,
                  canUpdate: false,
                  canArchive: false,
                  canEditContent: false)
    }
}

private nonisolated extension NitroTaskSnapshotStore.Metadata {
    init(_ metadata: NitroTaskMetadata) {
        title = metadata.title
        description = metadata.description
        batchID = metadata.batchID
        sourceRoomID = metadata.sourceRoomID
        sourceEventID = metadata.sourceEventID
        sourceThreadRootID = metadata.sourceThreadRootID
        sourcePermalink = metadata.sourcePermalink
        initialState = .init(metadata.initialState)
        createdDate = metadata.createdDate
    }
    
    var metadata: NitroTaskMetadata {
        NitroTaskMetadata(title: title,
                          description: description,
                          batchID: batchID,
                          sourceRoomID: sourceRoomID,
                          sourceEventID: sourceEventID,
                          sourceThreadRootID: sourceThreadRootID,
                          sourcePermalink: sourcePermalink,
                          initialState: initialState.state,
                          createdDate: createdDate)
    }
}

private nonisolated extension NitroTaskSnapshotStore.State {
    init(_ state: NitroTaskState) {
        status = state.status
        assignee = state.assignee
    }
    
    var state: NitroTaskState {
        NitroTaskState(status: status, assignee: assignee)
    }
}
