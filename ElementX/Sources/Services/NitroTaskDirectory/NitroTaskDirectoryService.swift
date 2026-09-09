//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK

nonisolated struct NitroTaskDirectoryResolution: Sendable {
    let hints: [NitroTaskDirectoryKey: NitroTaskDirectoryHint]
    let verificationRequired: Set<NitroTaskDirectoryKey>
    let storeMutationTokens: [NitroTaskDirectoryKey: UInt64]
}

protocol NitroTaskDirectoryServiceProtocol: AnyObject {
    var changedRoomIDsPublisher: AnyPublisher<Set<String>, Never> { get }
    
    func start()
    func stop()
    func resolve(_ keys: Set<NitroTaskDirectoryKey>) async -> NitroTaskDirectoryResolution
    func authoritativeFallbackResolution(_ resolution: NitroTaskDirectoryResolution) async -> NitroTaskDirectoryResolution
    func isCurrent(_ resolution: NitroTaskDirectoryResolution) async -> Bool
    func publish(_ updates: [NitroTaskDirectoryStoreUpdate],
                 clearingVerificationRequired keys: Set<NitroTaskDirectoryKey>,
                 expectedMutationTokens: [NitroTaskDirectoryKey: UInt64]) async -> Bool
    func markVerificationRequired(_ keys: Set<NitroTaskDirectoryKey>) async
}

final class NitroTaskDirectoryService: NitroTaskDirectoryServiceProtocol {
    private struct StoreWrite {
        let update: RoomTimelineUpdate
        let roomID: String
        let runID: UUID
    }
    
    private struct RoomObservation {
        let pinnedEventsHandle: TaskHandle
        let timelineHandle: TaskHandle?
        let eventCacheHandle: TaskHandle?
        
        var observesTimeline: Bool {
            timelineHandle != nil
        }
        
        func cancel() {
            pinnedEventsHandle.cancel()
            timelineHandle?.cancel()
            eventCacheHandle?.cancel()
        }
    }
    
    private static let initialRetryDelay: Duration = .seconds(1)
    private static let maximumRetryDelay: Duration = .seconds(30)
    private static let pinnedEventsType = "m.room.pinned_events"
    private let client: ClientProtocol
    private let api: any NitroTaskDirectoryClientProtocol
    private let store: any NitroTaskDirectoryStoreProtocol
    private let roomListService: RoomListService?
    private let changedRoomIDsSubject = PassthroughSubject<Set<String>, Never>()
    private var runID: UUID?
    private var flushTask: Task<Void, Never>?
    private var flushRequested = false
    private var roomObservationRefreshTask: Task<Void, Never>?
    private var roomObservations = [String: RoomObservation]()
    private var pendingStoreWrites = [StoreWrite]()
    private var storeWriteTask: Task<Void, Never>?
    private var storeWriteTaskID: UUID?
    private var activeSubscriptionName: String?
    private var subscribedRoomIDs = Set<String>()
    private var retryDelay = initialRetryDelay
    private var runToken: NitroTaskDirectoryRunToken?
    
    var changedRoomIDsPublisher: AnyPublisher<Set<String>, Never> {
        changedRoomIDsSubject.eraseToAnyPublisher()
    }
    
    init(client: ClientProtocol,
         api: any NitroTaskDirectoryClientProtocol,
         store: any NitroTaskDirectoryStoreProtocol,
         roomListService: RoomListService? = nil) {
        self.client = client
        self.api = api
        self.store = store
        self.roomListService = roomListService
    }
    
    func start() {
        guard runID == nil else { return }
        let runID = UUID()
        let runToken = NitroTaskDirectoryRunToken()
        let subscriptionName = "nitro-task-directory-\(runID.uuidString)"
        self.runID = runID
        self.runToken = runToken
        activeSubscriptionName = subscriptionName
        subscribedRoomIDs = []
        roomObservationRefreshTask = Task { [weak self] in
            await self?.publishPersistedChanges(runID: runID)
            while !Task.isCancelled {
                await self?.refreshRoomObservations(runID: runID, subscriptionName: subscriptionName)
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
            }
        }
        scheduleFlush(after: .zero)
    }
    
    private func publishPersistedChanges(runID: UUID) async {
        let roomIDs = await store.dirtyRoomIDs()
        guard self.runID == runID, !Task.isCancelled, !roomIDs.isEmpty else { return }
        changedRoomIDsSubject.send(roomIDs)
    }
    
    func stop() {
        let subscriptionName = activeSubscriptionName
        runToken?.invalidate()
        runID = nil
        runToken = nil
        activeSubscriptionName = nil
        subscribedRoomIDs = []
        flushTask?.cancel()
        flushTask = nil
        flushRequested = false
        roomObservationRefreshTask?.cancel()
        roomObservationRefreshTask = nil
        storeWriteTask?.cancel()
        storeWriteTask = nil
        storeWriteTaskID = nil
        pendingStoreWrites.removeAll()
        roomObservations.values.forEach { $0.cancel() }
        roomObservations.removeAll()
        if let roomListService, let subscriptionName {
            Task {
                try? await roomListService.setSupplementalRoomSubscription(name: subscriptionName, roomIds: [])
            }
        }
    }
    
    func resolve(_ keys: Set<NitroTaskDirectoryKey>) async -> NitroTaskDirectoryResolution {
        let beforeRequest = await store.verificationSnapshot(for: keys)
        let hints: [NitroTaskDirectoryKey: NitroTaskDirectoryHint]
        if keys.isEmpty {
            hints = [:]
        } else {
            do {
                let authentication = try await authentication()
                hints = try await api.resolve(Array(keys), authentication: authentication)
            } catch is CancellationError {
                hints = [:]
            } catch {
                MXLog.info("Nitro task directory unavailable; using Matrix fallback: \(error)")
                hints = [:]
            }
        }
        let afterRequest = await store.verificationSnapshot(for: keys)
        let changedDuringRequest = Set(keys.filter {
            beforeRequest.mutationTokens[$0, default: 0] != afterRequest.mutationTokens[$0, default: 0]
        })
        return .init(hints: hints,
                     verificationRequired: afterRequest.requiredKeys.union(changedDuringRequest),
                     storeMutationTokens: afterRequest.mutationTokens)
    }
    
    func authoritativeFallbackResolution(_ resolution: NitroTaskDirectoryResolution) async -> NitroTaskDirectoryResolution {
        let keys = Set(resolution.storeMutationTokens.keys)
        let verification = await store.verificationSnapshot(for: keys)
        return .init(hints: resolution.hints,
                     verificationRequired: keys,
                     storeMutationTokens: verification.mutationTokens)
    }
    
    func isCurrent(_ resolution: NitroTaskDirectoryResolution) async -> Bool {
        await store.areMutationTokensCurrent(resolution.storeMutationTokens)
    }
    
    func publish(_ updates: [NitroTaskDirectoryStoreUpdate],
                 clearingVerificationRequired keys: Set<NitroTaskDirectoryKey>,
                 expectedMutationTokens: [NitroTaskDirectoryKey: UInt64]) async -> Bool {
        guard let runID, let runToken, !updates.isEmpty else { return false }
        guard await store.applyIfMutationTokensCurrent(updates,
                                                       clearingVerificationRequired: keys,
                                                       expectedTokens: expectedMutationTokens,
                                                       runToken: runToken) else {
            return false
        }
        guard self.runID == runID, !Task.isCancelled else { return false }
        scheduleFlush(after: .milliseconds(250))
        return true
    }
    
    func markVerificationRequired(_ keys: Set<NitroTaskDirectoryKey>) async {
        guard let runToken else { return }
        await store.markVerificationRequired(keys, runToken: runToken)
    }
    
    func receiveTimelineUpdate(_ update: RoomTimelineUpdate, roomID: String) {
        guard let runID else { return }
        handle(update, roomID: roomID, runID: runID)
    }
    
    private func scheduleFlush(after delay: Duration) {
        guard let runID else { return }
        guard flushTask == nil else {
            flushRequested = true
            return
        }
        flushRequested = false
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                await self?.flush(runID: runID)
            } catch { }
        }
    }
    
    private func flush(runID: UUID) async {
        guard self.runID == runID, let runToken else { return }
        let pending = await store.pendingUpdates()
        guard self.runID == runID, !Task.isCancelled else { return }
        guard !pending.isEmpty else {
            flushTask = nil
            retryDelay = Self.initialRetryDelay
            if flushRequested {
                scheduleFlush(after: .milliseconds(250))
            }
            return
        }
        let entries = pending.map(\.update)
        do {
            let authentication = try await authentication()
            let results = try await api.update(entries, authentication: authentication)
            guard self.runID == runID, !Task.isCancelled else { return }
            let conflicts = Set(results.lazy.filter(\.hasConflict).map(\.key))
            await store.markVerificationRequired(conflicts, runToken: runToken)
            guard self.runID == runID, !Task.isCancelled else { return }
            await store.acknowledge(pending, runToken: runToken)
            guard self.runID == runID, !Task.isCancelled else { return }
            retryDelay = Self.initialRetryDelay
            flushTask = nil
            scheduleFlush(after: .milliseconds(250))
        } catch is CancellationError {
            guard self.runID == runID else { return }
            flushTask = nil
        } catch {
            guard self.runID == runID, !Task.isCancelled else { return }
            MXLog.info("Failed updating Nitro task directory; retrying: \(error)")
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, Self.maximumRetryDelay)
            flushTask = nil
            scheduleFlush(after: delay)
        }
    }
    
    private func authentication() async throws -> NitroTaskDirectoryAuthentication {
        let session = try client.session()
        let token = try await client.requestOpenidToken()
        return .init(homeserverURL: session.homeserverUrl,
                     openIDToken: .init(accessToken: token.accessToken,
                                        tokenType: token.tokenType,
                                        matrixServerName: token.matrixServerName))
    }
    
    private func refreshRoomObservations(runID: UUID, subscriptionName: String) async {
        guard self.runID == runID else { return }
        let index = await NitroTaskIndex.decode(try? client.accountData(eventType: NitroTaskEventParser.taskIndexEventType))
        guard self.runID == runID, !Task.isCancelled else { return }
        let indexedRoomIDs = Set(index?.tasks.map(\.roomID) ?? [])
        if let roomListService, subscribedRoomIDs != indexedRoomIDs {
            do {
                try await roomListService.setSupplementalRoomSubscription(name: subscriptionName,
                                                                          roomIds: indexedRoomIDs.sorted())
                guard self.runID == runID, !Task.isCancelled else {
                    try? await roomListService.setSupplementalRoomSubscription(name: subscriptionName, roomIds: [])
                    return
                }
                subscribedRoomIDs = indexedRoomIDs
            } catch { }
        }
        guard self.runID == runID, !Task.isCancelled else { return }
        let rooms = client.rooms().filter { $0.membership() == .joined && !$0.isSpace() }
        let roomIDs = Set(rooms.map { $0.id() })
        let removedRoomIDs = roomObservations.keys.filter { !roomIDs.contains($0) }
        for roomID in removedRoomIDs {
            roomObservations[roomID]?.cancel()
            roomObservations[roomID] = nil
        }
        for room in rooms {
            let roomID = room.id()
            let observesTimeline = indexedRoomIDs.contains(roomID)
            if roomObservations[roomID]?.observesTimeline == observesTimeline {
                continue
            }
            roomObservations[roomID]?.cancel()
            let pinnedEventsListener = SDKListener<Void>.onMainActor { [weak self] _ in
                self?.handlePinnedEventsChange(roomID: roomID, runID: runID)
            }
            let pinnedEventsHandle = room.subscribeToRoomStateUpdates(eventTypes: [Self.pinnedEventsType],
                                                                      listener: pinnedEventsListener)
            if observesTimeline {
                let timelineListener = SDKListener<RoomTimelineUpdate>.onMainActor { [weak self] update in
                    self?.handle(update, roomID: roomID, runID: runID)
                }
                roomObservations[roomID] = .init(pinnedEventsHandle: pinnedEventsHandle,
                                                 timelineHandle: room.subscribeToTimelineUpdates(listener: timelineListener),
                                                 eventCacheHandle: room.subscribeToEventCacheUpdates(listener: timelineListener))
            } else {
                roomObservations[roomID] = .init(pinnedEventsHandle: pinnedEventsHandle,
                                                 timelineHandle: nil,
                                                 eventCacheHandle: nil)
            }
        }
    }
    
    private func handlePinnedEventsChange(roomID: String, runID: UUID) {
        guard self.runID == runID else { return }
        changedRoomIDsSubject.send([roomID])
    }
    
    private func handle(_ update: RoomTimelineUpdate, roomID: String, runID: UUID) {
        guard self.runID == runID else { return }
        pendingStoreWrites.append(.init(update: update, roomID: roomID, runID: runID))
        startStoreWriter(runID: runID)
    }
    
    private func startStoreWriter(runID: UUID) {
        guard storeWriteTask == nil else { return }
        let taskID = UUID()
        storeWriteTaskID = taskID
        storeWriteTask = Task { [weak self] in
            await self?.drainStoreWrites(runID: runID, taskID: taskID)
        }
    }
    
    private func drainStoreWrites(runID: UUID, taskID: UUID) async {
        while self.runID == runID, !Task.isCancelled, !pendingStoreWrites.isEmpty {
            let write = pendingStoreWrites.removeFirst()
            guard write.runID == runID else { continue }
            await process(write)
        }
        guard storeWriteTaskID == taskID else { return }
        storeWriteTask = nil
        storeWriteTaskID = nil
        if self.runID == runID, !pendingStoreWrites.isEmpty {
            startStoreWriter(runID: runID)
        }
    }
    
    private func process(_ write: StoreWrite) async {
        guard runID == write.runID, let runToken, !Task.isCancelled else { return }
        var verificationRequired = Set<NitroTaskDirectoryKey>()
        var updates = [NitroTaskDirectoryStoreUpdate]()
        if Self.requiresRoomVerification(write.update) {
            verificationRequired = await timelineGapKeys(roomID: write.roomID, runID: write.runID)
            updates.append(contentsOf: verificationRequired.map {
                .init(update: .init(key: $0, invalidates: true), dimension: .invalidate)
            })
        }
        let eventUpdates = await Self.storeUpdates(from: write.update.events, roomID: write.roomID)
        let eventKeys = Set(eventUpdates.map(\.update.key))
        let affectedKeys = eventKeys.union(verificationRequired)
        let mutationTokensBeforeUpdate = if affectedKeys.isEmpty {
            [NitroTaskDirectoryKey: UInt64]()
        } else {
            await store.verificationSnapshot(for: affectedKeys).mutationTokens
        }
        updates.append(contentsOf: eventUpdates)
        guard runID == write.runID, !Task.isCancelled, !updates.isEmpty || !verificationRequired.isEmpty else { return }
        await store.apply(updates, verificationRequired: verificationRequired, runToken: runToken)
        guard runID == write.runID, !Task.isCancelled else { return }
        guard !affectedKeys.isEmpty else {
            scheduleFlush(after: .milliseconds(250))
            return
        }
        let mutationTokensAfterUpdate = await store.verificationSnapshot(for: affectedKeys).mutationTokens
        guard runID == write.runID, !Task.isCancelled else { return }
        if affectedKeys.contains(where: { mutationTokensBeforeUpdate[$0] != mutationTokensAfterUpdate[$0] }) {
            changedRoomIDsSubject.send([write.roomID])
        }
        scheduleFlush(after: .milliseconds(250))
    }
    
    nonisolated static func requiresRoomVerification(_ update: RoomTimelineUpdate) -> Bool {
        update.limited || update.lagged
    }
    
    @concurrent
    private static func storeUpdates(from events: [String], roomID: String) async -> [NitroTaskDirectoryStoreUpdate] {
        var updates = [NitroTaskDirectoryUpdateDimension: [NitroTaskDirectoryKey: NitroTaskDirectoryStoreUpdate]]()
        for (index, json) in events.enumerated() {
            if index.isMultiple(of: 100), Task.isCancelled {
                return []
            }
            guard let pointer = NitroTaskEventParser.directoryPointer(from: json) else { continue }
            let entry: NitroTaskDirectoryStoreUpdate
            switch pointer {
            case .content(let taskEventID, let eventID, let originTimestamp):
                let key = NitroTaskDirectoryKey(roomID: roomID, taskEventID: taskEventID)
                entry = .init(update: .init(key: key,
                                            contentEventID: eventID,
                                            contentOriginTimestamp: originTimestamp),
                              dimension: .content)
            case .state(let taskEventID, let eventID, let originTimestamp):
                let key = NitroTaskDirectoryKey(roomID: roomID, taskEventID: taskEventID)
                entry = .init(update: .init(key: key,
                                            statePointer: .event(id: eventID, originTimestamp: originTimestamp)),
                              dimension: .state)
            }
            updates[entry.dimension, default: [:]][entry.update.key] = entry
        }
        return updates.values.flatMap(\.values)
    }
    
    private func timelineGapKeys(roomID: String, runID: UUID) async -> Set<NitroTaskDirectoryKey> {
        guard self.runID == runID, !Task.isCancelled,
              let index = await NitroTaskIndex.decode(try? client.accountData(eventType: NitroTaskEventParser.taskIndexEventType)) else {
            return []
        }
        let keys = Set(index.eventIDs(in: roomID).map { NitroTaskDirectoryKey(roomID: roomID, taskEventID: $0) })
        guard self.runID == runID, !Task.isCancelled else { return [] }
        return keys
    }
}
