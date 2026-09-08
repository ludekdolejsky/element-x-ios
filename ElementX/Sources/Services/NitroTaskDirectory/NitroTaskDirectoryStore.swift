//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation

nonisolated enum NitroTaskDirectoryUpdateDimension: String, Codable, Sendable {
    case content
    case state
    case authoritative
    case invalidate
}

nonisolated struct NitroTaskDirectoryPendingUpdate: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let dimension: NitroTaskDirectoryUpdateDimension
    let update: NitroTaskDirectoryUpdate
}

nonisolated struct NitroTaskDirectoryStoreUpdate: Sendable {
    let update: NitroTaskDirectoryUpdate
    let dimension: NitroTaskDirectoryUpdateDimension
}

nonisolated struct NitroTaskDirectoryVerificationSnapshot: Sendable {
    let requiredKeys: Set<NitroTaskDirectoryKey>
    let mutationTokens: [NitroTaskDirectoryKey: UInt64]
}

nonisolated protocol NitroTaskDirectoryStoreProtocol: Sendable {
    func verificationSnapshot(for keys: Set<NitroTaskDirectoryKey>) async -> NitroTaskDirectoryVerificationSnapshot
    func areMutationTokensCurrent(_ tokens: [NitroTaskDirectoryKey: UInt64]) async -> Bool
    func markVerificationRequired(_ keys: Set<NitroTaskDirectoryKey>, runToken: NitroTaskDirectoryRunToken?) async
    func apply(_ updates: [NitroTaskDirectoryStoreUpdate], verificationRequired: Set<NitroTaskDirectoryKey>,
               runToken: NitroTaskDirectoryRunToken?) async
    func applyIfMutationTokensCurrent(_ updates: [NitroTaskDirectoryStoreUpdate],
                                      clearingVerificationRequired keys: Set<NitroTaskDirectoryKey>,
                                      expectedTokens: [NitroTaskDirectoryKey: UInt64],
                                      runToken: NitroTaskDirectoryRunToken?) async -> Bool
    func pendingUpdates() async -> [NitroTaskDirectoryPendingUpdate]
    func acknowledge(_ updates: [NitroTaskDirectoryPendingUpdate], runToken: NitroTaskDirectoryRunToken?) async
}

actor NitroTaskDirectoryStore: NitroTaskDirectoryStoreProtocol {
    private struct EventPointer: Codable, Equatable, Sendable {
        let eventID: String
        let originTimestamp: UInt64
    }
    
    private struct VerifiedPointers: Codable, Equatable, Sendable {
        var content: EventPointer?
        var state: EventPointer?
    }
    
    private struct Snapshot: Codable, Sendable {
        static let currentVersion = 1
        let version: Int
        var verificationRequired: Set<NitroTaskDirectoryKey>
        var pendingUpdates: [NitroTaskDirectoryPendingUpdate]
        var verifiedPointers: [NitroTaskDirectoryKey: VerifiedPointers]
        
        private enum CodingKeys: String, CodingKey {
            case version
            case verificationRequired
            case pendingUpdates
            case verifiedPointers
        }
        
        init(version: Int,
             verificationRequired: Set<NitroTaskDirectoryKey>,
             pendingUpdates: [NitroTaskDirectoryPendingUpdate],
             verifiedPointers: [NitroTaskDirectoryKey: VerifiedPointers] = [:]) {
            self.version = version
            self.verificationRequired = verificationRequired
            self.pendingUpdates = pendingUpdates
            self.verifiedPointers = verifiedPointers
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            verificationRequired = try container.decode(Set<NitroTaskDirectoryKey>.self, forKey: .verificationRequired)
            pendingUpdates = try container.decode([NitroTaskDirectoryPendingUpdate].self, forKey: .pendingUpdates)
            verifiedPointers = try container.decodeIfPresent([NitroTaskDirectoryKey: VerifiedPointers].self,
                                                             forKey: .verifiedPointers) ?? [:]
        }
    }
    
    private static let fileName = "nitro-task-directory-v1"
    private static let keyContext = Data("com.nitrovery.elementx.task-directory-v1".utf8)
    private static let maximumEntryCount = 5000
    private static let maximumPayloadSize = 4 * 1024 * 1024
    private let fileURL: URL
    private let key: SymmetricKey
    private var snapshot: Snapshot?
    private var nextMutationToken: UInt64 = 0
    private var mutationTokens = [NitroTaskDirectoryKey: UInt64]()
    
    init(storageDirectory: URL, passphrase: String) {
        fileURL = storageDirectory.appending(component: Self.fileName)
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
                                     salt: Self.keyContext,
                                     info: Self.keyContext,
                                     outputByteCount: 32)
    }
    
    func verificationSnapshot(for keys: Set<NitroTaskDirectoryKey>) async -> NitroTaskDirectoryVerificationSnapshot {
        let snapshot = loadIfNeeded()
        let dirtyKeys = Set(snapshot.pendingUpdates.map(\.update.key))
        return .init(requiredKeys: snapshot.verificationRequired.union(dirtyKeys).intersection(keys),
                     mutationTokens: Dictionary(uniqueKeysWithValues: keys.map { ($0, mutationTokens[$0, default: 0]) }))
    }
    
    func areMutationTokensCurrent(_ tokens: [NitroTaskDirectoryKey: UInt64]) async -> Bool {
        tokens.allSatisfy { mutationTokens[$0.key, default: 0] == $0.value }
    }
    
    func markVerificationRequired(_ keys: Set<NitroTaskDirectoryKey>, runToken: NitroTaskDirectoryRunToken? = nil) async {
        guard !Task.isCancelled, !keys.isEmpty else { return }
        perform(runToken: runToken) {
            var snapshot = loadIfNeeded()
            let previous = snapshot.verificationRequired
            snapshot.verificationRequired.formUnion(keys)
            trim(&snapshot.verificationRequired)
            guard snapshot.verificationRequired != previous else { return }
            guard save(snapshot) else { return }
            bumpMutationTokens(for: previous.symmetricDifference(snapshot.verificationRequired))
        }
    }
    
    func apply(_ updates: [NitroTaskDirectoryStoreUpdate], verificationRequired: Set<NitroTaskDirectoryKey>,
               runToken: NitroTaskDirectoryRunToken? = nil) async {
        guard !Task.isCancelled, !updates.isEmpty || !verificationRequired.isEmpty else { return }
        perform(runToken: runToken) {
            _ = applyMutations(updates,
                               verificationRequired: verificationRequired,
                               clearingVerificationRequired: [])
        }
    }
    
    func applyIfMutationTokensCurrent(_ updates: [NitroTaskDirectoryStoreUpdate],
                                      clearingVerificationRequired keys: Set<NitroTaskDirectoryKey>,
                                      expectedTokens: [NitroTaskDirectoryKey: UInt64],
                                      runToken: NitroTaskDirectoryRunToken? = nil) async -> Bool {
        let updateKeys = Set(updates.map(\.update.key))
        guard !Task.isCancelled,
              !updates.isEmpty,
              updateKeys.isSubset(of: expectedTokens.keys),
              keys.isSubset(of: expectedTokens.keys),
              expectedTokens.allSatisfy({ mutationTokens[$0.key, default: 0] == $0.value }) else {
            return false
        }
        return performIfActiveReturningSuccess(runToken: runToken) {
            applyMutations(updates,
                           verificationRequired: [],
                           clearingVerificationRequired: keys)
        }
    }
    
    @discardableResult
    private func applyMutations(_ updates: [NitroTaskDirectoryStoreUpdate],
                                verificationRequired: Set<NitroTaskDirectoryKey>,
                                clearingVerificationRequired keysToClear: Set<NitroTaskDirectoryKey>) -> Bool {
        var snapshot = loadIfNeeded()
        var changedKeys = Set<NitroTaskDirectoryKey>()
        let previousVerificationRequired = snapshot.verificationRequired
        snapshot.verificationRequired.formUnion(verificationRequired)
        for var entry in updates {
            let pointerChanged: Bool
            switch entry.dimension {
            case .content, .state:
                guard let observedEntry = observedEntry(from: entry, in: snapshot) else { continue }
                entry = observedEntry
                snapshot.verificationRequired.insert(entry.update.key)
                pointerChanged = false
            case .authoritative:
                pointerChanged = applyVerifiedPointers(entry.update, to: &snapshot)
            case .invalidate:
                pointerChanged = false
            }
            let pendingUpdateChanged = !isDuplicate(entry, in: snapshot.pendingUpdates)
            guard pointerChanged || pendingUpdateChanged else { continue }
            if entry.dimension == .invalidate {
                snapshot.verificationRequired.insert(entry.update.key)
            }
            if pendingUpdateChanged {
                if entry.dimension == .authoritative {
                    snapshot.pendingUpdates.removeAll { $0.update.key == entry.update.key }
                } else {
                    snapshot.pendingUpdates.removeAll { $0.dimension == entry.dimension && $0.update.key == entry.update.key }
                }
                snapshot.pendingUpdates.append(.init(id: UUID(), dimension: entry.dimension, update: entry.update))
            }
            changedKeys.insert(entry.update.key)
        }
        snapshot.verificationRequired.subtract(keysToClear)
        if snapshot.pendingUpdates.count > Self.maximumEntryCount {
            let removed = snapshot.pendingUpdates.prefix(snapshot.pendingUpdates.count - Self.maximumEntryCount)
            snapshot.verificationRequired.formUnion(removed.map(\.update.key))
            changedKeys.formUnion(removed.map(\.update.key))
            snapshot.pendingUpdates.removeFirst(snapshot.pendingUpdates.count - Self.maximumEntryCount)
        }
        trim(&snapshot.verificationRequired)
        trimVerifiedPointers(in: &snapshot)
        changedKeys.formUnion(previousVerificationRequired.symmetricDifference(snapshot.verificationRequired))
        guard !changedKeys.isEmpty else { return true }
        guard save(snapshot) else { return false }
        bumpMutationTokens(for: changedKeys)
        return true
    }
    
    func pendingUpdates() async -> [NitroTaskDirectoryPendingUpdate] {
        loadIfNeeded().pendingUpdates
    }
    
    func acknowledge(_ updates: [NitroTaskDirectoryPendingUpdate], runToken: NitroTaskDirectoryRunToken? = nil) async {
        guard !Task.isCancelled, !updates.isEmpty else { return }
        perform(runToken: runToken) {
            var snapshot = loadIfNeeded()
            let identifiers = Set(updates.map(\.id))
            let removedKeys = Set(snapshot.pendingUpdates.lazy.filter { identifiers.contains($0.id) }.map(\.update.key))
            guard !removedKeys.isEmpty else { return }
            snapshot.pendingUpdates.removeAll { identifiers.contains($0.id) }
            guard persist(snapshot) else { return }
            self.snapshot = snapshot
            bumpMutationTokens(for: removedKeys)
        }
    }
    
    @discardableResult
    private func perform(runToken: NitroTaskDirectoryRunToken?, operation: () -> Void) -> Bool {
        guard let runToken else {
            operation()
            return true
        }
        return runToken.performIfActive(operation)
    }
    
    private func performIfActiveReturningSuccess(runToken: NitroTaskDirectoryRunToken?,
                                                 operation: () -> Bool) -> Bool {
        guard let runToken else { return operation() }
        return runToken.performIfActiveReturningSuccess(operation)
    }
    
    private func isDuplicate(_ entry: NitroTaskDirectoryStoreUpdate,
                             in pendingUpdates: [NitroTaskDirectoryPendingUpdate]) -> Bool {
        let matching = pendingUpdates.filter { $0.update.key == entry.update.key }
        if entry.dimension == .authoritative {
            return matching.count == 1 && matching[0].dimension == entry.dimension && matching[0].update == entry.update
        }
        return matching.contains { $0.dimension == entry.dimension && $0.update == entry.update }
    }
    
    private func observedEntry(from entry: NitroTaskDirectoryStoreUpdate,
                               in snapshot: Snapshot) -> NitroTaskDirectoryStoreUpdate? {
        let candidate: EventPointer
        let verified: EventPointer?
        switch entry.dimension {
        case .content:
            guard let eventID = entry.update.contentEventID,
                  let originTimestamp = entry.update.contentOriginTimestamp else {
                return nil
            }
            candidate = .init(eventID: eventID, originTimestamp: originTimestamp)
            verified = snapshot.verifiedPointers[entry.update.key]?.content
            if eventID == entry.update.key.taskEventID,
               let verified,
               verified.eventID != entry.update.key.taskEventID {
                return nil
            }
        case .state:
            guard case .some(.event(let eventID, let originTimestamp)) = entry.update.statePointer else {
                return nil
            }
            candidate = .init(eventID: eventID, originTimestamp: originTimestamp)
            verified = snapshot.verifiedPointers[entry.update.key]?.state
        case .authoritative, .invalidate:
            return nil
        }
        guard candidate != verified else { return nil }
        var update = entry.update
        update.invalidates = true
        return .init(update: update, dimension: entry.dimension)
    }
    
    private func applyVerifiedPointers(_ update: NitroTaskDirectoryUpdate, to snapshot: inout Snapshot) -> Bool {
        var pointers = snapshot.verifiedPointers[update.key] ?? .init()
        let previous = pointers
        if let eventID = update.contentEventID, let originTimestamp = update.contentOriginTimestamp {
            pointers.content = .init(eventID: eventID, originTimestamp: originTimestamp)
        }
        switch update.statePointer {
        case .some(.event(let eventID, let originTimestamp)):
            pointers.state = .init(eventID: eventID, originTimestamp: originTimestamp)
        case .some(.none):
            pointers.state = nil
        case nil:
            break
        }
        guard pointers != previous else { return false }
        snapshot.verifiedPointers[update.key] = pointers
        return true
    }
    
    private func loadIfNeeded() -> Snapshot {
        if let snapshot {
            return snapshot
        }
        let loaded = load() ?? .init(version: Snapshot.currentVersion,
                                     verificationRequired: [],
                                     pendingUpdates: [],
                                     verifiedPointers: [:])
        snapshot = loaded
        return loaded
    }
    
    private func load() -> Snapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        do {
            let encryptedData = try Data(contentsOf: fileURL)
            guard encryptedData.count <= Self.maximumPayloadSize + 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            let data = try AES.GCM.open(sealedBox, using: key, authenticating: Self.keyContext)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == Snapshot.currentVersion,
                  snapshot.verificationRequired.count <= Self.maximumEntryCount,
                  snapshot.pendingUpdates.count <= Self.maximumEntryCount,
                  snapshot.verifiedPointers.count <= Self.maximumEntryCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return snapshot
        } catch {
            MXLog.info("Ignoring invalid Nitro task directory state: \(error)")
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }
    
    @discardableResult
    private func save(_ snapshot: Snapshot) -> Bool {
        guard persist(snapshot) else { return false }
        self.snapshot = snapshot
        return true
    }
    
    private func persist(_ snapshot: Snapshot) -> Bool {
        do {
            guard FileManager.default.directoryExists(at: fileURL.deletingLastPathComponent()) else { return false }
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= Self.maximumPayloadSize else { throw CocoaError(.fileWriteOutOfSpace) }
            let sealedBox = try AES.GCM.seal(data, using: key, authenticating: Self.keyContext)
            guard let encryptedData = sealedBox.combined else { return false }
            try encryptedData.write(to: fileURL,
                                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            MXLog.error("Failed saving Nitro task directory state: \(error)")
            return false
        }
    }
    
    private func trim(_ keys: inout Set<NitroTaskDirectoryKey>) {
        guard keys.count > Self.maximumEntryCount else { return }
        keys = Set(keys.prefix(Self.maximumEntryCount))
    }
    
    private func trimVerifiedPointers(in snapshot: inout Snapshot) {
        guard snapshot.verifiedPointers.count > Self.maximumEntryCount else { return }
        let protectedKeys = snapshot.verificationRequired.union(snapshot.pendingUpdates.map(\.update.key))
        let removableKeys = snapshot.verifiedPointers.keys.filter { !protectedKeys.contains($0) }
        for key in removableKeys.prefix(snapshot.verifiedPointers.count - Self.maximumEntryCount) {
            snapshot.verifiedPointers[key] = nil
        }
        while snapshot.verifiedPointers.count > Self.maximumEntryCount, let key = snapshot.verifiedPointers.keys.first {
            snapshot.verifiedPointers[key] = nil
        }
    }
    
    private func bumpMutationTokens(for keys: Set<NitroTaskDirectoryKey>) {
        for key in keys {
            nextMutationToken &+= 1
            mutationTokens[key] = nextMutationToken
        }
    }
}
