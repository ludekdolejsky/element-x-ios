//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

struct NitroTaskDirectoryServiceTests {
    @Test
    func resolveIncludesVerificationChangesObservedDuringRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let api = NitroTaskDirectoryAPIMock {
            await store.markVerificationRequired([key])
        }
        let service = NitroTaskDirectoryService(client: makeClient(), api: api, store: store)
        
        let resolution = await service.resolve([key])
        
        #expect(resolution.verificationRequired == [key])
        #expect(resolution.hints.isEmpty)
        #expect(await service.isCurrent(resolution))
    }
    
    @Test
    func resolutionBecomesStaleAfterObservedStoreWrite() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let hint = try makeHint(key: key, revision: 7)
        let service = NitroTaskDirectoryService(client: makeClient(), api: NitroTaskDirectoryAPIMock(hints: [key: hint]), store: store)
        let resolution = await service.resolve([key])
        
        await store.apply([.init(update: .init(key: key,
                                               statePointer: .event(id: "$state:example.org", originTimestamp: 1)),
            dimension: .state)],
                          verificationRequired: [])
        
        #expect(await !(service.isCurrent(resolution)))
        let fallback = await service.authoritativeFallbackResolution(resolution)
        #expect(fallback.hints[key]?.revision == 7)
        #expect(fallback.verificationRequired == [key])
        #expect(await service.isCurrent(fallback))
    }
    
    @Test
    func transientStoreMutationDuringResolveRequiresVerification() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let hint = try makeHint(key: key, revision: 3)
        let api = NitroTaskDirectoryAPIMock(hints: [key: hint]) {
            await store.apply([.init(update: .init(key: key,
                                                   contentEventID: "$new-edit:example.org",
                                                   contentOriginTimestamp: 2),
                dimension: .content)],
                              verificationRequired: [])
            await store.acknowledge(store.pendingUpdates())
        }
        let service = NitroTaskDirectoryService(client: makeClient(), api: api, store: store)
        
        let resolution = await service.resolve([key])
        
        #expect(resolution.hints[key]?.revision == 3)
        #expect(resolution.verificationRequired == [key])
        #expect(await service.isCurrent(resolution))
    }
    
    @Test
    func unrelatedStoreMutationDoesNotInvalidateResolution() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let unrelatedKey = NitroTaskDirectoryKey(roomID: "!other:example.org", taskEventID: "$other:example.org")
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let service = NitroTaskDirectoryService(client: makeClient(), api: NitroTaskDirectoryAPIMock(), store: store)
        let resolution = await service.resolve([key])
        
        await store.apply([.init(update: .init(key: unrelatedKey,
                                               contentEventID: "$edit:example.org",
                                               contentOriginTimestamp: 1),
            dimension: .content)],
                          verificationRequired: [])
        
        #expect(await service.isCurrent(resolution))
    }
    
    @Test
    func stoppedServiceCannotPublishACompletedScan() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let service = NitroTaskDirectoryService(client: makeClient(), api: NitroTaskDirectoryAPIMock(), store: store)
        let resolution = await service.resolve([key])
        let update = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                 contentEventID: "$content:example.org",
                                                                 contentOriginTimestamp: 1,
                                                                 statePointer: NitroTaskDirectoryStatePointer.none,
                                                                 isAuthoritative: true),
                                                   dimension: .authoritative)
        
        service.start()
        service.stop()
        let applied = await service.publish([update],
                                            clearingVerificationRequired: [],
                                            expectedMutationTokens: resolution.storeMutationTokens)
        
        #expect(!applied)
        #expect(await store.pendingUpdates().isEmpty)
    }
    
    @Test
    func updateQueuedWhileAnEmptyFlushIsFinishingIsStillSent() async {
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let store = FlushRaceTaskDirectoryStore()
        let api = NitroTaskDirectoryAPIMock()
        let service = NitroTaskDirectoryService(client: makeClient(), api: api, store: store)
        let update = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                 contentEventID: "$content:example.org",
                                                                 contentOriginTimestamp: 1,
                                                                 statePointer: NitroTaskDirectoryStatePointer.none,
                                                                 isAuthoritative: true),
                                                   dimension: .authoritative)
        
        service.start()
        await store.waitUntilFirstPendingReadStarts()
        let resolution = await store.verificationSnapshot(for: [key])
        #expect(await service.publish([update],
                                      clearingVerificationRequired: [],
                                      expectedMutationTokens: resolution.mutationTokens))
        await store.finishFirstPendingRead()
        
        let sentUpdates = await api.waitForUpdate()
        #expect(sentUpdates == [update.update])
        service.stop()
    }
    
    @Test
    func invalidSingleDimensionHintRepairsTheOtherDimension() {
        let invalidContent = NitroTaskService.directoryRepairDimensions(contentIsAuthoritative: true,
                                                                        contentRequiresRepair: true,
                                                                        stateIsAuthoritative: false,
                                                                        stateRequiresRepair: false)
        let invalidState = NitroTaskService.directoryRepairDimensions(contentIsAuthoritative: false,
                                                                      contentRequiresRepair: false,
                                                                      stateIsAuthoritative: true,
                                                                      stateRequiresRepair: true)
        
        #expect(!invalidContent.content)
        #expect(invalidContent.state)
        #expect(invalidState.content)
        #expect(!invalidState.state)
    }
    
    @Test
    func contentHintMustMatchTheLocallyKnownPointerAndTimestamp() throws {
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let hint = try makeHint(key: key, revision: 1)
        
        #expect(NitroTaskService.directoryContentPointerMatches(hint,
                                                                currentEventID: "$content:example.org",
                                                                currentOriginTimestamp: 1))
        #expect(!NitroTaskService.directoryContentPointerMatches(hint,
                                                                 currentEventID: "$task:example.org",
                                                                 currentOriginTimestamp: 1))
        #expect(!NitroTaskService.directoryContentPointerMatches(hint,
                                                                 currentEventID: "$content:example.org",
                                                                 currentOriginTimestamp: 2))
    }
    
    private func makeClient() -> ClientSDKMock {
        let client = ClientSDKMock(.init())
        client.requestOpenidTokenReturnValue = OpenIdToken(accessToken: "token",
                                                           tokenType: "Bearer",
                                                           matrixServerName: "example.org",
                                                           expiresInSeconds: 3600)
        client.roomsReturnValue = []
        return client
    }
    
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(component: "nitro-task-directory-service-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    
    private func makeHint(key: NitroTaskDirectoryKey, revision: UInt64) throws -> NitroTaskDirectoryHint {
        let data = try JSONSerialization.data(withJSONObject: [
            "room_id": key.roomID,
            "task_event_id": key.taskEventID,
            "content_event_id": "$content:example.org",
            "content_origin_ts": 1,
            "revision": revision,
            "fresh": true
        ])
        return try JSONDecoder().decode(NitroTaskDirectoryHint.self, from: data)
    }
}

private actor NitroTaskDirectoryAPIMock: NitroTaskDirectoryClientProtocol {
    private let hints: [NitroTaskDirectoryKey: NitroTaskDirectoryHint]
    private let onResolve: @Sendable () async -> Void
    private var receivedUpdates = [[NitroTaskDirectoryUpdate]]()
    private var updateWaiters = [CheckedContinuation<[NitroTaskDirectoryUpdate], Never>]()
    
    init(hints: [NitroTaskDirectoryKey: NitroTaskDirectoryHint] = [:],
         onResolve: @escaping @Sendable () async -> Void = { }) {
        self.hints = hints
        self.onResolve = onResolve
    }
    
    func resolve(_ keys: [NitroTaskDirectoryKey],
                 authentication: NitroTaskDirectoryAuthentication) async throws -> [NitroTaskDirectoryKey: NitroTaskDirectoryHint] {
        await onResolve()
        return hints
    }
    
    func update(_ entries: [NitroTaskDirectoryUpdate],
                authentication: NitroTaskDirectoryAuthentication) async throws -> [NitroTaskDirectoryUpdateResult] {
        receivedUpdates.append(entries)
        updateWaiters.forEach { $0.resume(returning: entries) }
        updateWaiters.removeAll()
        return []
    }
    
    func waitForUpdate() async -> [NitroTaskDirectoryUpdate] {
        if let updates = receivedUpdates.first {
            return updates
        }
        return await withCheckedContinuation { updateWaiters.append($0) }
    }
}

private actor FlushRaceTaskDirectoryStore: NitroTaskDirectoryStoreProtocol {
    private var pending = [NitroTaskDirectoryPendingUpdate]()
    private var firstPendingReadStarted = false
    private var pendingReadWaiters = [CheckedContinuation<Void, Never>]()
    private var firstPendingReadContinuation: CheckedContinuation<Void, Never>?
    
    func verificationSnapshot(for keys: Set<NitroTaskDirectoryKey>) async -> NitroTaskDirectoryVerificationSnapshot {
        .init(requiredKeys: [],
              mutationTokens: Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) }))
    }
    
    func areMutationTokensCurrent(_ tokens: [NitroTaskDirectoryKey: UInt64]) async -> Bool {
        true
    }
    
    func markVerificationRequired(_ keys: Set<NitroTaskDirectoryKey>, runToken: NitroTaskDirectoryRunToken?) async { }
    
    func apply(_ updates: [NitroTaskDirectoryStoreUpdate], verificationRequired: Set<NitroTaskDirectoryKey>,
               runToken: NitroTaskDirectoryRunToken?) async { }
    
    func applyIfMutationTokensCurrent(_ updates: [NitroTaskDirectoryStoreUpdate],
                                      clearingVerificationRequired keys: Set<NitroTaskDirectoryKey>,
                                      expectedTokens: [NitroTaskDirectoryKey: UInt64],
                                      runToken: NitroTaskDirectoryRunToken?) async -> Bool {
        pending.append(contentsOf: updates.map {
            .init(id: UUID(), dimension: $0.dimension, update: $0.update)
        })
        return true
    }
    
    func pendingUpdates() async -> [NitroTaskDirectoryPendingUpdate] {
        guard !firstPendingReadStarted else { return pending }
        firstPendingReadStarted = true
        pendingReadWaiters.forEach { $0.resume() }
        pendingReadWaiters.removeAll()
        await withCheckedContinuation { firstPendingReadContinuation = $0 }
        return []
    }
    
    func acknowledge(_ updates: [NitroTaskDirectoryPendingUpdate], runToken: NitroTaskDirectoryRunToken?) async {
        let identifiers = Set(updates.map(\.id))
        pending.removeAll { identifiers.contains($0.id) }
    }
    
    func waitUntilFirstPendingReadStarts() async {
        guard !firstPendingReadStarted else { return }
        await withCheckedContinuation { pendingReadWaiters.append($0) }
    }
    
    func finishFirstPendingRead() {
        firstPendingReadContinuation?.resume()
        firstPendingReadContinuation = nil
    }
}
