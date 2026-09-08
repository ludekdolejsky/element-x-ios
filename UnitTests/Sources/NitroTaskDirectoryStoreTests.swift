//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroTaskDirectoryStoreTests {
    @Test
    func verificationMarkerSurvivesRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let writer = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        await writer.markVerificationRequired([key])
        
        let reader = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let snapshot = await reader.verificationSnapshot(for: [key])
        
        #expect(snapshot.requiredKeys == [key])
    }
    
    @Test
    func staleAcknowledgementDoesNotDeleteNewerPendingUpdate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        await store.apply([.init(update: .init(key: key,
                                               statePointer: .event(id: "$first:example.org", originTimestamp: 1)),
            dimension: .state)],
                          verificationRequired: [])
        let first = await store.pendingUpdates()
        await store.apply([.init(update: .init(key: key,
                                               statePointer: .event(id: "$second:example.org", originTimestamp: 2)),
            dimension: .state)],
                          verificationRequired: [])
        
        await store.acknowledge(first)
        let remaining = await store.pendingUpdates()
        
        #expect(remaining.count == 1)
        #expect(remaining.first?.update.statePointer == .event(id: "$second:example.org", originTimestamp: 2))
    }
    
    @Test
    func authoritativeScanSupersedesObservedAndInvalidationUpdates() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        await store.apply([.init(update: .init(key: key,
                                               contentEventID: "$edit:example.org",
                                               contentOriginTimestamp: 1),
                                 dimension: .content),
                           .init(update: .init(key: key,
                                               statePointer: .event(id: "$state:example.org", originTimestamp: 2)),
                                 dimension: .state),
                           .init(update: .init(key: key, invalidates: true), dimension: .invalidate)],
                          verificationRequired: [])
        
        let authoritative = NitroTaskDirectoryUpdate(key: key,
                                                     contentEventID: "$latest:example.org",
                                                     contentOriginTimestamp: 3,
                                                     statePointer: .event(id: "$latest-state:example.org", originTimestamp: 4),
                                                     isAuthoritative: true)
        await store.apply([.init(update: authoritative, dimension: .authoritative)], verificationRequired: [])
        
        let pending = await store.pendingUpdates()
        #expect(pending.count == 1)
        #expect(pending.first?.dimension == .authoritative)
        #expect(pending.first?.update == authoritative)
    }
    
    @Test
    func storesOnlyEncryptedOpaquePointers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        await store.apply([.init(update: .init(key: key,
                                               contentEventID: "$edit:example.org",
                                               contentOriginTimestamp: 1),
            dimension: .content)],
                          verificationRequired: [])
        let fileURL = try #require(FileManager.default.contentsOfDirectory(at: directory,
                                                                           includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: fileURL)
        
        #expect(data.range(of: Data("!room:example.org".utf8)) == nil)
        #expect(data.range(of: Data("$task:example.org".utf8)) == nil)
        #expect(data.range(of: Data("$edit:example.org".utf8)) == nil)
    }
    
    @Test
    func cancelledWriteDoesNotMutatePersistentState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let writeTask = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch { }
            await store.apply([.init(update: .init(key: key,
                                                   contentEventID: "$edit:example.org",
                                                   contentOriginTimestamp: 1),
                dimension: .content)],
                              verificationRequired: [])
        }
        writeTask.cancel()
        await writeTask.value
        
        let pending = await store.pendingUpdates()
        #expect(pending.isEmpty)
    }
    
    @Test
    func observedWriteInvalidatesExistingResolutionToken() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let snapshot = await store.verificationSnapshot(for: [key])
        
        await store.apply([.init(update: .init(key: key,
                                               contentEventID: "$edit:example.org",
                                               contentOriginTimestamp: 1),
            dimension: .content)],
                          verificationRequired: [])
        
        #expect(await !(store.areMutationTokensCurrent(snapshot.mutationTokens)))
    }
    
    @Test
    func unrelatedWriteDoesNotInvalidateResolutionToken() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let requestedKey = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$requested:example.org")
        let unrelatedKey = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$unrelated:example.org")
        let snapshot = await store.verificationSnapshot(for: [requestedKey])
        
        await store.apply([.init(update: .init(key: unrelatedKey,
                                               contentEventID: "$edit:example.org",
                                               contentOriginTimestamp: 1),
            dimension: .content)],
                          verificationRequired: [])
        
        #expect(await store.areMutationTokensCurrent(snapshot.mutationTokens))
    }
    
    @Test
    func staleAuthoritativeBatchCannotReplaceNewerObservedUpdates() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let snapshot = await store.verificationSnapshot(for: [key])
        let observed = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                   statePointer: .event(id: "$new-state:example.org",
                                                                                        originTimestamp: 2)),
                                                     dimension: .state)
        await store.apply([observed], verificationRequired: [])
        let stale = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                contentEventID: "$old-content:example.org",
                                                                contentOriginTimestamp: 1,
                                                                statePointer: NitroTaskDirectoryStatePointer.none,
                                                                isAuthoritative: true),
                                                  dimension: .authoritative)
        
        let applied = await store.applyIfMutationTokensCurrent([stale],
                                                               clearingVerificationRequired: [],
                                                               expectedTokens: snapshot.mutationTokens)
        let pending = await store.pendingUpdates()
        
        #expect(!applied)
        #expect(pending.count == 1)
        #expect(pending.first?.update.statePointer == observed.update.statePointer)
        #expect(pending.first?.update.invalidates == true)
    }
    
    @Test
    func currentAuthoritativeBatchIsAppliedTogether() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let firstKey = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$first:example.org")
        let secondKey = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$second:example.org")
        let keys: Set = [firstKey, secondKey]
        let snapshot = await store.verificationSnapshot(for: keys)
        let updates = keys.map {
            NitroTaskDirectoryStoreUpdate(update: .init(key: $0,
                                                        contentEventID: "$content:example.org",
                                                        contentOriginTimestamp: 1,
                                                        statePointer: NitroTaskDirectoryStatePointer.none,
                                                        isAuthoritative: true),
                                          dimension: .authoritative)
        }
        
        let applied = await store.applyIfMutationTokensCurrent(updates,
                                                               clearingVerificationRequired: [],
                                                               expectedTokens: snapshot.mutationTokens)
        let pending = await store.pendingUpdates()
        
        #expect(applied)
        #expect(pending.count == 2)
        #expect(Set(pending.map(\.update.key)) == keys)
    }
    
    @Test
    func authoritativeBatchClearsOnlyItsVerificationMarkerAfterUnrelatedMutation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let scannedKey = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$scanned:example.org")
        let unrelatedKey = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$unrelated:example.org")
        await store.markVerificationRequired([scannedKey])
        let snapshot = await store.verificationSnapshot(for: [scannedKey])
        await store.markVerificationRequired([unrelatedKey])
        let update = NitroTaskDirectoryStoreUpdate(update: .init(key: scannedKey,
                                                                 contentEventID: "$content:example.org",
                                                                 contentOriginTimestamp: 1,
                                                                 statePointer: NitroTaskDirectoryStatePointer.none,
                                                                 isAuthoritative: true),
                                                   dimension: .authoritative)
        
        let applied = await store.applyIfMutationTokensCurrent([update],
                                                               clearingVerificationRequired: [scannedKey],
                                                               expectedTokens: snapshot.mutationTokens)
        await store.acknowledge(store.pendingUpdates())
        let verification = await store.verificationSnapshot(for: [scannedKey, unrelatedKey])
        
        #expect(applied)
        #expect(verification.requiredKeys == [unrelatedKey])
    }
    
    @Test
    func authoritativeBatchRequiresMutationTokenForEveryTask() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let knownKey = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$known:example.org")
        let discoveredKey = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$discovered:example.org")
        let snapshot = await store.verificationSnapshot(for: [knownKey])
        let update = NitroTaskDirectoryStoreUpdate(update: .init(key: discoveredKey,
                                                                 contentEventID: "$content:example.org",
                                                                 contentOriginTimestamp: 1,
                                                                 statePointer: NitroTaskDirectoryStatePointer.none,
                                                                 isAuthoritative: true),
                                                   dimension: .authoritative)
        
        let applied = await store.applyIfMutationTokensCurrent([update],
                                                               clearingVerificationRequired: [],
                                                               expectedTokens: snapshot.mutationTokens)
        
        #expect(!applied)
        #expect(await store.pendingUpdates().isEmpty)
    }
    
    @Test
    func invalidatedRunCannotMutateStore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let snapshot = await store.verificationSnapshot(for: [key])
        let update = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                 contentEventID: "$content:example.org",
                                                                 contentOriginTimestamp: 1,
                                                                 statePointer: NitroTaskDirectoryStatePointer.none,
                                                                 isAuthoritative: true),
                                                   dimension: .authoritative)
        let runToken = NitroTaskDirectoryRunToken()
        runToken.invalidate()
        
        let applied = await store.applyIfMutationTokensCurrent([update],
                                                               clearingVerificationRequired: [],
                                                               expectedTokens: snapshot.mutationTokens,
                                                               runToken: runToken)
        
        #expect(!applied)
        #expect(await store.pendingUpdates().isEmpty)
    }
    
    @Test
    func duplicatePendingObservedPointerIsANoOp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let update = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                 contentEventID: "$content:example.org",
                                                                 contentOriginTimestamp: 1),
                                                   dimension: .content)
        await store.apply([update], verificationRequired: [])
        let pendingBeforeDuplicate = await store.pendingUpdates()
        let tokenBeforeDuplicate = await store.verificationSnapshot(for: [key]).mutationTokens
        
        await store.apply([update], verificationRequired: [])
        
        #expect(await store.pendingUpdates() == pendingBeforeDuplicate)
        #expect(await store.areMutationTokensCurrent(tokenBeforeDuplicate))
    }
    
    @Test
    func observedPointerMatchingVerifiedPointerIsANoOpAfterRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let authoritative = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                        contentEventID: "$content:example.org",
                                                                        contentOriginTimestamp: 1,
                                                                        statePointer: NitroTaskDirectoryStatePointer.none,
                                                                        isAuthoritative: true),
                                                          dimension: .authoritative)
        let writer = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let snapshot = await writer.verificationSnapshot(for: [key])
        #expect(await writer.applyIfMutationTokensCurrent([authoritative],
                                                          clearingVerificationRequired: [],
                                                          expectedTokens: snapshot.mutationTokens))
        await writer.acknowledge(writer.pendingUpdates())
        let reader = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let observed = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                   contentEventID: "$content:example.org",
                                                                   contentOriginTimestamp: 1),
                                                     dimension: .content)
        let token = await reader.verificationSnapshot(for: [key]).mutationTokens
        
        await reader.apply([observed], verificationRequired: [])
        
        #expect(await reader.pendingUpdates().isEmpty)
        #expect(await reader.verificationSnapshot(for: [key]).requiredKeys.isEmpty)
        #expect(await reader.areMutationTokensCurrent(token))
    }
    
    @Test
    func historicalRootDoesNotInvalidateVerifiedEditAfterRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let verified = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                   contentEventID: "$edit:example.org",
                                                                   contentOriginTimestamp: 2,
                                                                   statePointer: NitroTaskDirectoryStatePointer.none,
                                                                   isAuthoritative: true),
                                                     dimension: .authoritative)
        let writer = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let writerSnapshot = await writer.verificationSnapshot(for: [key])
        #expect(await writer.applyIfMutationTokensCurrent([verified],
                                                          clearingVerificationRequired: [],
                                                          expectedTokens: writerSnapshot.mutationTokens))
        await writer.acknowledge(writer.pendingUpdates())
        let reader = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let historicalRoot = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                         contentEventID: key.taskEventID,
                                                                         contentOriginTimestamp: 1),
                                                           dimension: .content)
        let token = await reader.verificationSnapshot(for: [key]).mutationTokens
        
        await reader.apply([historicalRoot], verificationRequired: [])
        
        #expect(await reader.pendingUpdates().isEmpty)
        #expect(await reader.verificationSnapshot(for: [key]).requiredKeys.isEmpty)
        #expect(await reader.areMutationTokensCurrent(token))
    }
    
    @Test
    func lowerTimestampObservedPointerInvalidatesVerifiedPointerAfterRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let verified = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                   contentEventID: "$verified:example.org",
                                                                   contentOriginTimestamp: 2,
                                                                   statePointer: NitroTaskDirectoryStatePointer.none,
                                                                   isAuthoritative: true),
                                                     dimension: .authoritative)
        let writer = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let writerSnapshot = await writer.verificationSnapshot(for: [key])
        #expect(await writer.applyIfMutationTokensCurrent([verified],
                                                          clearingVerificationRequired: [],
                                                          expectedTokens: writerSnapshot.mutationTokens))
        await writer.acknowledge(writer.pendingUpdates())
        let reader = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let observed = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                   contentEventID: "$observed:example.org",
                                                                   contentOriginTimestamp: 1),
                                                     dimension: .content)
        
        await reader.apply([observed], verificationRequired: [])
        
        let pending = await reader.pendingUpdates()
        #expect(pending.count == 1)
        #expect(pending.first?.update.contentEventID == "$observed:example.org")
        #expect(pending.first?.update.invalidates == true)
        #expect(await reader.verificationSnapshot(for: [key]).requiredKeys == [key])
    }
    
    @Test
    func lowerTimestampObservedStateInvalidatesVerifiedPointerAfterRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let verified = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                   contentEventID: "$task:example.org",
                                                                   contentOriginTimestamp: 0,
                                                                   statePointer: .event(id: "$verified:example.org",
                                                                                        originTimestamp: 2),
                                                                   isAuthoritative: true),
                                                     dimension: .authoritative)
        let writer = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let writerSnapshot = await writer.verificationSnapshot(for: [key])
        #expect(await writer.applyIfMutationTokensCurrent([verified],
                                                          clearingVerificationRequired: [],
                                                          expectedTokens: writerSnapshot.mutationTokens))
        await writer.acknowledge(writer.pendingUpdates())
        let reader = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let observed = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                   statePointer: .event(id: "$observed:example.org",
                                                                                        originTimestamp: 1)),
                                                     dimension: .state)
        
        await reader.apply([observed], verificationRequired: [])
        
        let pending = await reader.pendingUpdates()
        #expect(pending.count == 1)
        #expect(pending.first?.update.statePointer == .event(id: "$observed:example.org", originTimestamp: 1))
        #expect(pending.first?.update.invalidates == true)
        #expect(await reader.verificationSnapshot(for: [key]).requiredKeys == [key])
    }
    
    @Test
    func failedPersistencePreventsAcknowledgement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        await store.apply([.init(update: .init(key: key,
                                               contentEventID: "$edit:example.org",
                                               contentOriginTimestamp: 1),
            dimension: .content)],
                          verificationRequired: [])
        let pending = await store.pendingUpdates()
        try FileManager.default.removeItem(at: directory)
        
        await store.acknowledge(pending)
        
        #expect(!pending.isEmpty)
        #expect(await store.pendingUpdates() == pending)
    }
    
    @Test
    func failedPersistencePreventsClearingVerificationMarker() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        await store.markVerificationRequired([key])
        let snapshot = await store.verificationSnapshot(for: [key])
        let update = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                 contentEventID: "$content:example.org",
                                                                 contentOriginTimestamp: 1,
                                                                 statePointer: NitroTaskDirectoryStatePointer.none,
                                                                 isAuthoritative: true),
                                                   dimension: .authoritative)
        try FileManager.default.removeItem(at: directory)
        
        let applied = await store.applyIfMutationTokensCurrent([update],
                                                               clearingVerificationRequired: [key],
                                                               expectedTokens: snapshot.mutationTokens)
        
        #expect(!applied)
        #expect(await store.verificationSnapshot(for: [key]).requiredKeys == [key])
    }
    
    @Test
    func failedPersistenceDoesNotAcceptAnAuthoritativeUpdate() async throws {
        let parentDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }
        let storageDirectory = parentDirectory.appending(component: "missing")
        let store = NitroTaskDirectoryStore(storageDirectory: storageDirectory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        let snapshot = await store.verificationSnapshot(for: [key])
        let update = NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                 contentEventID: "$content:example.org",
                                                                 contentOriginTimestamp: 1,
                                                                 statePointer: NitroTaskDirectoryStatePointer.none,
                                                                 isAuthoritative: true),
                                                   dimension: .authoritative)
        
        let applied = await store.applyIfMutationTokensCurrent([update],
                                                               clearingVerificationRequired: [],
                                                               expectedTokens: snapshot.mutationTokens)
        
        #expect(!applied)
        #expect(await store.pendingUpdates().isEmpty)
        #expect(await store.areMutationTokensCurrent(snapshot.mutationTokens))
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let restoredStore = NitroTaskDirectoryStore(storageDirectory: storageDirectory, passphrase: "session-key")
        #expect(await restoredStore.pendingUpdates().isEmpty)
    }
    
    @Test
    func failedPersistenceDoesNotExposeAnUnpersistedVerificationMarker() async throws {
        let parentDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }
        let storageDirectory = parentDirectory.appending(component: "missing")
        let store = NitroTaskDirectoryStore(storageDirectory: storageDirectory, passphrase: "session-key")
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        
        await store.markVerificationRequired([key])
        
        let snapshot = await store.verificationSnapshot(for: [key])
        #expect(snapshot.requiredKeys.isEmpty)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let restoredStore = NitroTaskDirectoryStore(storageDirectory: storageDirectory, passphrase: "session-key")
        #expect(await restoredStore.verificationSnapshot(for: [key]).requiredKeys.isEmpty)
    }
    
    @Test
    func queueOverflowMarksEvictedTaskForVerification() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NitroTaskDirectoryStore(storageDirectory: directory, passphrase: "session-key")
        let updates = (0...2500).flatMap { index in
            let timestamp = UInt64(index)
            let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task\(index):example.org")
            return [NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                contentEventID: "$edit\(index):example.org",
                                                                contentOriginTimestamp: timestamp),
                                                  dimension: .content),
                    NitroTaskDirectoryStoreUpdate(update: .init(key: key,
                                                                statePointer: .event(id: "$state\(index):example.org",
                                                                                     originTimestamp: timestamp)),
                                                  dimension: .state)]
        }
        
        await store.apply(updates, verificationRequired: [])
        
        let pending = await store.pendingUpdates()
        let evictedKey = updates[0].update.key
        let snapshot = await store.verificationSnapshot(for: [evictedKey])
        #expect(pending.count == 5000)
        #expect(snapshot.requiredKeys == [evictedKey])
    }
    
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(component: "nitro-task-directory-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
