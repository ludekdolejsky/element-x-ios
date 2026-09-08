//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

struct NitroTaskLoader {
    private nonisolated enum DirectoryContentResolution: Sendable {
        case content(NitroTaskService.LoadedTaskContent)
        case fallback(requiresRepair: Bool)
    }
    
    private nonisolated static let maximumConcurrentRoomLoads = 4
    private nonisolated static let maximumConcurrentTaskLoads = 12
    private nonisolated static let maximumDirectoryLoadAttempts = 2
    
    private let client: ClientProtocol
    private let urlSession: URLSession
    private let directoryService: (any NitroTaskDirectoryServiceProtocol)?
    
    init(client: ClientProtocol,
         urlSession: URLSession,
         directoryService: (any NitroTaskDirectoryServiceProtocol)?) {
        self.client = client
        self.urlSession = urlSession
        self.directoryService = directoryService
    }
    
    func load(index: NitroTaskIndex, roomIDs: Set<String>?) async throws -> NitroTaskService.LoadedTasks {
        let session = try client.session()
        let ownUserID = try client.userId()
        let indexedKeys = Set(index.tasks.lazy
            .filter { roomIDs?.contains($0.roomID) ?? true }
            .map { NitroTaskDirectoryKey(roomID: $0.roomID, taskEventID: $0.eventID) })
        let rooms = if let roomIDs {
            client.rooms().filter { roomIDs.contains($0.id()) }
        } else {
            client.rooms()
        }
        let preparationPerformance = NitroPerformance.start(name: "Nitro Tasks room preparation",
                                                            operation: "nitro.tasks.prepare_rooms")
        preparationPerformance.setData(rooms.count, key: "nitro.tasks.room_count")
        preparationPerformance.setData(indexedKeys.count, key: "nitro.tasks.indexed_count")
        async let taskPreparation = Self.prepareTaskRooms(in: rooms, index: index)
        async let initialDirectoryResolution = resolveDirectory(indexedKeys)
        let preparedTaskRooms: NitroTaskService.PreparedTaskRooms
        do {
            preparedTaskRooms = try await taskPreparation
            preparationPerformance.setData(preparedTaskRooms.preparedRooms.count, key: "nitro.tasks.prepared_room_count")
            preparationPerformance.finish(.success)
        } catch {
            preparationPerformance.finish(Task.isCancelled ? .cancelled : .failure)
            throw error
        }
        var directoryResolution = await initialDirectoryResolution
        let preparedKeys = Set(preparedTaskRooms.preparedRooms.flatMap { room in
            room.taskEvents.map { NitroTaskDirectoryKey(roomID: room.roomID, taskEventID: $0.eventID) }
        })
        let allKeys = indexedKeys.union(preparedKeys)
        if allKeys != indexedKeys {
            directoryResolution = await resolveDirectory(allKeys)
        }
        let hydrationPerformance = NitroPerformance.start(name: "Nitro Tasks hydration",
                                                          operation: "nitro.tasks.hydrate")
        hydrationPerformance.setData(allKeys.count, key: "nitro.tasks.task_count")
        do {
            let result = try await load(preparedTaskRooms,
                                        ownUserID: ownUserID,
                                        session: session,
                                        index: index,
                                        directoryResolution: directoryResolution)
            hydrationPerformance.setData(result.list.tasks.count, key: "nitro.tasks.loaded_count")
            hydrationPerformance.finish(.success)
            return result
        } catch {
            hydrationPerformance.finish(Task.isCancelled ? .cancelled : .failure)
            throw error
        }
    }
    
    private func resolveDirectory(_ keys: Set<NitroTaskDirectoryKey>) async -> NitroTaskDirectoryResolution {
        guard let directoryService else {
            return .init(hints: [:],
                         verificationRequired: [],
                         storeMutationTokens: [:])
        }
        return await directoryService.resolve(keys)
    }
    
    private func load(_ preparedTaskRooms: NitroTaskService.PreparedTaskRooms,
                      ownUserID: String,
                      session: Session,
                      index: NitroTaskIndex,
                      directoryResolution initialDirectoryResolution: NitroTaskDirectoryResolution) async throws -> NitroTaskService.LoadedTasks {
        try await loadWithConsistentDirectory(initialResolution: initialDirectoryResolution) { directoryResolution in
            try await Self.loadTasks(preparedTaskRooms,
                                     ownUserID: ownUserID,
                                     session: session,
                                     urlSession: urlSession,
                                     index: index,
                                     directoryResolution: directoryResolution)
        }
    }
    
    func loadWithConsistentDirectory(initialResolution: NitroTaskDirectoryResolution,
                                     operation: (NitroTaskDirectoryResolution) async throws -> NitroTaskService.LoadedTasks) async throws -> NitroTaskService.LoadedTasks {
        guard let directoryService else {
            return try await operation(initialResolution)
        }
        var directoryResolution = initialResolution
        for attempt in 0..<Self.maximumDirectoryLoadAttempts {
            if await !(directoryService.isCurrent(directoryResolution)) {
                directoryResolution = await directoryService.authoritativeFallbackResolution(directoryResolution)
            }
            let loadedTasks = try await operation(directoryResolution)
            try Task.checkCancellation()
            guard await directoryService.isCurrent(directoryResolution) else {
                guard attempt + 1 < Self.maximumDirectoryLoadAttempts else { throw CancellationError() }
                directoryResolution = await directoryService.authoritativeFallbackResolution(directoryResolution)
                continue
            }
            let updates = loadedTasks.directoryUpdates.map {
                NitroTaskDirectoryStoreUpdate(update: $0, dimension: .authoritative)
            }
            guard !updates.isEmpty else { return loadedTasks }
            if await directoryService.publish(updates,
                                              clearingVerificationRequired: loadedTasks.verifiedDirectoryKeys,
                                              expectedMutationTokens: directoryResolution.storeMutationTokens) {
                return loadedTasks
            }
            guard await !(directoryService.isCurrent(directoryResolution)) else {
                return loadedTasks
            }
            guard attempt + 1 < Self.maximumDirectoryLoadAttempts else { throw CancellationError() }
            directoryResolution = await directoryService.authoritativeFallbackResolution(directoryResolution)
        }
        throw CancellationError()
    }
    
    // MARK: - Loading
    
    @concurrent
    static func loadTask(_ taskEvent: NitroTaskEventParser.TaskEvent,
                         context: NitroTaskService.TaskLoadContext,
                         directoryHint: NitroTaskDirectoryHint?,
                         verificationRequired: Bool) async -> NitroTaskService.LoadedTask {
        var loadedContent = await loadTaskContent(taskEvent,
                                                  room: context.room,
                                                  session: context.session,
                                                  urlSession: context.urlSession,
                                                  directoryHint: directoryHint,
                                                  verificationRequired: verificationRequired)
        var loadedState = await loadTaskState(taskEventID: loadedContent.event.eventID,
                                              initialState: loadedContent.event.metadata.initialState,
                                              waitForDecryption: context.waitForDecryption,
                                              room: context.room,
                                              session: context.session,
                                              urlSession: context.urlSession,
                                              directoryHint: directoryHint,
                                              verificationRequired: verificationRequired)
        let repairDimensions = directoryRepairDimensions(contentIsAuthoritative: loadedContent.isAuthoritative,
                                                         contentRequiresRepair: loadedContent.requiresDirectoryRepair,
                                                         stateIsAuthoritative: loadedState.isAuthoritative,
                                                         stateRequiresRepair: loadedState.requiresDirectoryRepair)
        if repairDimensions.content {
            loadedContent = await loadTaskContent(taskEvent,
                                                  room: context.room,
                                                  session: context.session,
                                                  urlSession: context.urlSession,
                                                  directoryHint: nil,
                                                  verificationRequired: true)
        }
        if repairDimensions.state {
            loadedState = await loadTaskState(taskEventID: loadedContent.event.eventID,
                                              initialState: loadedContent.event.metadata.initialState,
                                              waitForDecryption: context.waitForDecryption,
                                              room: context.room,
                                              session: context.session,
                                              urlSession: context.urlSession,
                                              directoryHint: nil,
                                              verificationRequired: true)
        }
        let taskEvent = loadedContent.event
        let assigneeDisplayName: String? = if let assignee = loadedState.state.assignee {
            try? await context.room.memberDisplayName(userId: assignee)
        } else {
            nil
        }
        let task = NitroTask(id: taskEvent.eventID,
                             roomID: context.roomID,
                             roomName: context.roomName,
                             metadata: taskEvent.metadata,
                             state: loadedState.state,
                             stateIsAvailable: loadedState.isAvailable,
                             assigneeDisplayName: assigneeDisplayName,
                             updatedDate: loadedState.updatedDate,
                             canUpdate: context.canSend && loadedState.isAvailable,
                             canArchive: context.canPin,
                             canEditContent: context.canSend && taskEvent.senderID == context.ownUserID)
        let key = NitroTaskDirectoryKey(roomID: context.roomID, taskEventID: taskEvent.eventID)
        let statePointer = loadedState.eventID.map {
            NitroTaskDirectoryStatePointer.event(id: $0, originTimestamp: loadedState.originTimestamp ?? 0)
        } ?? .none
        let update: NitroTaskDirectoryUpdate? = if loadedContent.isAuthoritative, loadedState.isAuthoritative {
            NitroTaskDirectoryUpdate(key: key,
                                     baseRevision: directoryHint?.revision,
                                     contentEventID: taskEvent.contentEventID,
                                     contentOriginTimestamp: taskEvent.contentOriginTimestamp,
                                     statePointer: statePointer,
                                     isAuthoritative: true)
        } else {
            nil
        }
        return NitroTaskService.LoadedTask(task: task,
                                           directoryUpdate: update,
                                           verifiedDirectoryKey: verificationRequired && loadedContent.isAuthoritative && loadedState.isAuthoritative ? key : nil)
    }
    
    nonisolated static func directoryRepairDimensions(contentIsAuthoritative: Bool,
                                                      contentRequiresRepair: Bool,
                                                      stateIsAuthoritative: Bool,
                                                      stateRequiresRepair: Bool) -> (content: Bool, state: Bool) {
        let requiresRepair = contentRequiresRepair || stateRequiresRepair
        return (requiresRepair && !contentIsAuthoritative, requiresRepair && !stateIsAuthoritative)
    }
    
    @concurrent
    private static func loadTaskContent(_ taskEvent: NitroTaskEventParser.TaskEvent,
                                        room: MatrixRustSDK.Room,
                                        session: Session,
                                        urlSession: URLSession,
                                        directoryHint: NitroTaskDirectoryHint?,
                                        verificationRequired: Bool) async -> NitroTaskService.LoadedTaskContent {
        let requiresDirectoryRepair: Bool
        if let directoryHint {
            switch await loadTaskContentFromDirectory(taskEvent,
                                                      room: room,
                                                      hint: directoryHint,
                                                      verificationRequired: verificationRequired) {
            case .content(let content):
                return content
            case .fallback(let requiresRepair):
                requiresDirectoryRepair = requiresRepair
            }
        } else {
            requiresDirectoryRepair = false
        }
        do {
            let replacement = try await loadLatestTaskReplacement(taskEvent: taskEvent,
                                                                  room: room,
                                                                  session: session,
                                                                  urlSession: urlSession)
            return NitroTaskService.LoadedTaskContent(event: replacement ?? taskEvent,
                                                      isAuthoritative: true,
                                                      requiresDirectoryRepair: requiresDirectoryRepair)
        } catch is CancellationError {
            return NitroTaskService.LoadedTaskContent(event: taskEvent,
                                                      isAuthoritative: false,
                                                      requiresDirectoryRepair: requiresDirectoryRepair)
        } catch {
            MXLog.error("Failed resolving content for Nitro task \(taskEvent.eventID) with error: \(error)")
            return NitroTaskService.LoadedTaskContent(event: taskEvent,
                                                      isAuthoritative: false,
                                                      requiresDirectoryRepair: requiresDirectoryRepair)
        }
    }
    
    @concurrent
    private static func loadTaskContentFromDirectory(_ taskEvent: NitroTaskEventParser.TaskEvent,
                                                     room: MatrixRustSDK.Room,
                                                     hint: NitroTaskDirectoryHint,
                                                     verificationRequired: Bool) async -> DirectoryContentResolution {
        guard hint.isFresh, !verificationRequired else {
            return .fallback(requiresRepair: false)
        }
        if directoryContentPointerMatches(hint,
                                          currentEventID: taskEvent.contentEventID,
                                          currentOriginTimestamp: taskEvent.contentOriginTimestamp) {
            return .content(.init(event: taskEvent,
                                  isAuthoritative: false,
                                  requiresDirectoryRepair: false))
        }
        guard taskEvent.contentEventID == taskEvent.eventID else {
            return .fallback(requiresRepair: true)
        }
        do {
            guard let replacement = try await loadTaskReplacement(eventID: hint.contentEventID,
                                                                  taskEvent: taskEvent,
                                                                  room: room),
                replacement.contentOriginTimestamp == hint.contentOriginTimestamp else {
                return .fallback(requiresRepair: true)
            }
            return .content(.init(event: replacement,
                                  isAuthoritative: false,
                                  requiresDirectoryRepair: false))
        } catch is CancellationError {
            return .content(.init(event: taskEvent,
                                  isAuthoritative: false,
                                  requiresDirectoryRepair: false))
        } catch {
            MXLog.info("Ignoring invalid Nitro task directory content pointer for \(taskEvent.eventID): \(error)")
            return .fallback(requiresRepair: true)
        }
    }
    
    nonisolated static func directoryContentPointerMatches(_ hint: NitroTaskDirectoryHint,
                                                           currentEventID: String,
                                                           currentOriginTimestamp: UInt64) -> Bool {
        hint.contentEventID == currentEventID && hint.contentOriginTimestamp == currentOriginTimestamp
    }
    
    @concurrent
    private static func loadLatestTaskReplacement(taskEvent: NitroTaskEventParser.TaskEvent,
                                                  room: MatrixRustSDK.Room,
                                                  session: Session,
                                                  urlSession: URLSession) async throws -> NitroTaskEventParser.TaskEvent? {
        var paginationToken: String?
        var seenPaginationTokens = Set<String>()
        repeat {
            try Task.checkCancellation()
            guard let url = NitroTaskService.relationsURL(homeserver: session.homeserverUrl,
                                                          roomID: room.id(),
                                                          eventID: taskEvent.eventID,
                                                          relationType: "m.replace",
                                                          from: paginationToken) else {
                throw NitroTaskService.InternalError.invalidResponse
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await urlSession.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = page["chunk"] as? [[String: Any]] else {
                throw NitroTaskService.InternalError.invalidResponse
            }
            for event in events {
                try Task.checkCancellation()
                guard let eventID = event["event_id"] as? String else { continue }
                if let json = try? NitroTaskService.jsonString(from: event),
                   let replacement = NitroTaskEventParser.replacementTaskEvent(from: json,
                                                                               replacing: taskEvent,
                                                                               roomID: room.id(),
                                                                               eventID: eventID) {
                    return replacement
                }
                guard event["type"] as? String == "m.room.encrypted" else { continue }
                if let replacement = try await loadTaskReplacement(eventID: eventID,
                                                                   taskEvent: taskEvent,
                                                                   room: room) {
                    return replacement
                }
            }
            paginationToken = page["next_batch"] as? String
            if let paginationToken, !seenPaginationTokens.insert(paginationToken).inserted {
                throw NitroTaskService.InternalError.invalidResponse
            }
        } while paginationToken != nil
        return nil
    }
    
    @concurrent
    private static func loadTaskReplacement(eventID: String,
                                            taskEvent: NitroTaskEventParser.TaskEvent,
                                            room: MatrixRustSDK.Room) async throws -> NitroTaskEventParser.TaskEvent? {
        let loadedEventJSON = try await NitroTaskService.loadedEventJSON(eventID: eventID,
                                                                         waitForDecryption: false,
                                                                         room: room)
        guard case let .event(originalJSON, latestJSON) = loadedEventJSON,
              let json = originalJSON ?? latestJSON else {
            throw NitroTaskService.InternalError.stateUnavailable
        }
        return NitroTaskEventParser.replacementTaskEvent(from: json,
                                                         replacing: taskEvent,
                                                         roomID: room.id(),
                                                         eventID: eventID)
    }
    
    @concurrent
    private static func loadTaskState(taskEventID: String,
                                      initialState: NitroTaskState,
                                      waitForDecryption: Bool,
                                      room: MatrixRustSDK.Room,
                                      session: Session,
                                      urlSession: URLSession,
                                      directoryHint: NitroTaskDirectoryHint?,
                                      verificationRequired: Bool) async -> NitroTaskService.LoadedTaskState {
        var requiresDirectoryRepair = false
        do {
            if let directoryHint,
               directoryHint.isFresh,
               !verificationRequired {
                if let state = try await loadTaskStateFromDirectory(taskEventID: taskEventID,
                                                                    initialState: initialState,
                                                                    waitForDecryption: waitForDecryption,
                                                                    room: room,
                                                                    hint: directoryHint) {
                    return state
                }
                requiresDirectoryRepair = true
            }
            let state = try await scanLatestTaskState(taskEventID: taskEventID,
                                                      initialState: initialState,
                                                      waitForDecryption: waitForDecryption,
                                                      room: room,
                                                      session: session,
                                                      urlSession: urlSession)
            return NitroTaskService.LoadedTaskState(state: state.state,
                                                    updatedDate: state.updatedDate,
                                                    isAvailable: state.isAvailable,
                                                    eventID: state.eventID,
                                                    originTimestamp: state.originTimestamp,
                                                    isAuthoritative: state.isAuthoritative,
                                                    requiresDirectoryRepair: requiresDirectoryRepair)
        } catch is CancellationError {
            return NitroTaskService.LoadedTaskState(state: initialState,
                                                    updatedDate: nil,
                                                    isAvailable: false,
                                                    eventID: nil,
                                                    originTimestamp: nil,
                                                    isAuthoritative: false,
                                                    requiresDirectoryRepair: requiresDirectoryRepair)
        } catch {
            MXLog.error("Failed resolving state for Nitro task \(taskEventID) with error: \(error)")
            return NitroTaskService.LoadedTaskState(state: initialState,
                                                    updatedDate: nil,
                                                    isAvailable: false,
                                                    eventID: nil,
                                                    originTimestamp: nil,
                                                    isAuthoritative: false,
                                                    requiresDirectoryRepair: requiresDirectoryRepair)
        }
    }
    
    @concurrent
    private static func loadTaskStateFromDirectory(taskEventID: String,
                                                   initialState: NitroTaskState,
                                                   waitForDecryption: Bool,
                                                   room: MatrixRustSDK.Room,
                                                   hint: NitroTaskDirectoryHint) async throws -> NitroTaskService.LoadedTaskState? {
        guard let eventID = hint.stateEventID else {
            return NitroTaskService.LoadedTaskState(state: initialState,
                                                    updatedDate: nil,
                                                    isAvailable: true,
                                                    eventID: nil,
                                                    originTimestamp: nil,
                                                    isAuthoritative: false,
                                                    requiresDirectoryRepair: false)
        }
        do {
            guard let update = try await loadTaskStateUpdate(eventID: eventID,
                                                             taskEventID: taskEventID,
                                                             waitForDecryption: waitForDecryption,
                                                             room: room),
                update.originTimestamp == hint.stateOriginTimestamp else {
                return nil
            }
            return NitroTaskService.LoadedTaskState(state: update.state,
                                                    updatedDate: update.updatedDate,
                                                    isAvailable: true,
                                                    eventID: eventID,
                                                    originTimestamp: hint.stateOriginTimestamp,
                                                    isAuthoritative: false,
                                                    requiresDirectoryRepair: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            MXLog.info("Ignoring invalid Nitro task directory state pointer for \(taskEventID): \(error)")
            return nil
        }
    }
    
    @concurrent
    private static func scanLatestTaskState(taskEventID: String,
                                            initialState: NitroTaskState,
                                            waitForDecryption: Bool,
                                            room: MatrixRustSDK.Room,
                                            session: Session,
                                            urlSession: URLSession) async throws -> NitroTaskService.LoadedTaskState {
        var paginationToken: String?
        var seenPaginationTokens = Set<String>()
        repeat {
            try Task.checkCancellation()
            guard let url = NitroTaskService.relationsURL(homeserver: session.homeserverUrl,
                                                          roomID: room.id(),
                                                          eventID: taskEventID,
                                                          relationType: "m.reference",
                                                          from: paginationToken) else {
                throw NitroTaskService.InternalError.invalidResponse
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await urlSession.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = page["chunk"] as? [[String: Any]] else {
                throw NitroTaskService.InternalError.invalidResponse
            }
            for event in events {
                if let state = try await taskState(eventJSON: try? NitroTaskService.jsonString(from: event),
                                                   eventID: event["event_id"] as? String,
                                                   isEncrypted: event["type"] as? String == "m.room.encrypted",
                                                   taskEventID: taskEventID,
                                                   waitForDecryption: waitForDecryption,
                                                   room: room) {
                    return state
                }
            }
            paginationToken = page["next_batch"] as? String
            if let paginationToken, !seenPaginationTokens.insert(paginationToken).inserted {
                throw NitroTaskService.InternalError.invalidResponse
            }
        } while paginationToken != nil
        return NitroTaskService.LoadedTaskState(state: initialState,
                                                updatedDate: nil,
                                                isAvailable: true,
                                                eventID: nil,
                                                originTimestamp: nil,
                                                isAuthoritative: true,
                                                requiresDirectoryRepair: false)
    }
    
    @concurrent
    private static func taskState(eventJSON: String?,
                                  eventID: String?,
                                  isEncrypted: Bool,
                                  taskEventID: String,
                                  waitForDecryption: Bool,
                                  room: MatrixRustSDK.Room) async throws -> NitroTaskService.LoadedTaskState? {
        try Task.checkCancellation()
        let update: NitroTaskEventParser.StateUpdate?
        if let eventJSON,
           let parsedUpdate = NitroTaskEventParser.stateUpdate(from: eventJSON,
                                                               taskEventID: taskEventID,
                                                               roomID: room.id()) {
            update = parsedUpdate
        } else if isEncrypted, let eventID {
            update = try await loadTaskStateUpdate(eventID: eventID,
                                                   taskEventID: taskEventID,
                                                   waitForDecryption: waitForDecryption,
                                                   room: room)
        } else {
            return nil
        }
        guard let update else { return nil }
        return NitroTaskService.LoadedTaskState(state: update.state,
                                                updatedDate: update.updatedDate,
                                                isAvailable: true,
                                                eventID: eventID,
                                                originTimestamp: update.originTimestamp,
                                                isAuthoritative: eventID != nil && update.originTimestamp != nil,
                                                requiresDirectoryRepair: false)
    }
    
    @concurrent
    private static func loadTaskStateUpdate(eventID: String,
                                            taskEventID: String,
                                            waitForDecryption: Bool,
                                            room: MatrixRustSDK.Room) async throws -> NitroTaskEventParser.StateUpdate? {
        let loadedEventJSON = try await NitroTaskService.loadedEventJSON(eventID: eventID,
                                                                         waitForDecryption: waitForDecryption,
                                                                         room: room)
        guard case let .event(originalJSON, latestJSON) = loadedEventJSON else {
            if case .unableToDecrypt = loadedEventJSON {
                throw NitroTaskService.InternalError.stateUnavailable
            }
            return nil
        }
        guard let json = originalJSON ?? latestJSON else { return nil }
        return NitroTaskEventParser.stateUpdate(from: json,
                                                taskEventID: taskEventID,
                                                roomID: room.id(),
                                                eventID: eventID)
    }
    
    @concurrent
    static func prepareTaskRooms(in rooms: [MatrixRustSDK.Room],
                                 index: NitroTaskIndex) async throws -> NitroTaskService.PreparedTaskRooms {
        try Task.checkCancellation()
        let joinedRooms = rooms.filter { $0.membership() == .joined && !$0.isSpace() }
        var iterator = joinedRooms.makeIterator()
        var loadedRooms = [NitroTaskService.LoadedRoomTasks]()
        var preparedRooms = [NitroTaskService.PreparedRoomTasks]()
        
        await withTaskGroup(of: NitroTaskService.RoomPreparationResult.self) { group in
            for _ in 0..<min(maximumConcurrentRoomLoads, joinedRooms.count) {
                guard !Task.isCancelled, let room = iterator.next() else { break }
                group.addTask {
                    await prepareTasks(in: room, index: index)
                }
            }
            
            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                switch result {
                case .prepared(let room):
                    preparedRooms.append(room)
                case .loaded(let room):
                    loadedRooms.append(room)
                }
                if let room = iterator.next() {
                    group.addTask {
                        await prepareTasks(in: room, index: index)
                    }
                }
            }
        }
        try Task.checkCancellation()
        return .init(loadedRooms: loadedRooms, preparedRooms: preparedRooms)
    }
    
    @concurrent
    static func loadTasks(_ taskRooms: NitroTaskService.PreparedTaskRooms,
                          ownUserID: String,
                          session: Session,
                          urlSession: URLSession,
                          index: NitroTaskIndex,
                          directoryResolution: NitroTaskDirectoryResolution) async throws -> NitroTaskService.LoadedTasks {
        try Task.checkCancellation()
        let loadedPreparedTasks = await loadPreparedTasks(taskRooms.preparedRooms,
                                                          ownUserID: ownUserID,
                                                          session: session,
                                                          urlSession: urlSession,
                                                          index: index,
                                                          directoryResolution: directoryResolution)
        var loadedRooms = taskRooms.loadedRooms
        loadedRooms.append(contentsOf: loadedPreparedTasks.rooms)
        try Task.checkCancellation()
        let tasks = loadedRooms
            .flatMap(\.tasks)
            .sorted { lhs, rhs in
                lhs.metadata.createdDate != rhs.metadata.createdDate
                    ? lhs.metadata.createdDate > rhs.metadata.createdDate
                    : lhs.id < rhs.id
            }
        let recoveryCandidates = loadedRooms.flatMap(\.recoveryCandidates)
        let unavailableRoomIDs = Set(loadedRooms.lazy
            .filter(\.isUnavailable)
            .map(\.reconciliation.roomID))
        return NitroTaskService.LoadedTasks(list: .init(tasks: tasks,
                                                        unavailableRoomCount: unavailableRoomIDs.count,
                                                        pendingEventCount: recoveryCandidates.count),
                                            recoveryCandidates: recoveryCandidates,
                                            reconciliations: loadedRooms.map(\.reconciliation),
                                            unavailableRoomIDs: unavailableRoomIDs,
                                            directoryUpdates: loadedPreparedTasks.directoryUpdates,
                                            verifiedDirectoryKeys: loadedPreparedTasks.verifiedDirectoryKeys)
    }
    
    @concurrent
    private static func prepareTasks(in room: MatrixRustSDK.Room,
                                     index: NitroTaskIndex) async -> NitroTaskService.RoomPreparationResult {
        let roomID = room.id()
        let indexedEventIDs = index.eventIDs(in: roomID)
        do {
            try Task.checkCancellation()
            let info = try await room.roomInfo()
            guard info.membership == .joined,
                  !info.isSpace,
                  info.successorRoom == nil else {
                return .loaded(NitroTaskService.LoadedRoomTasks(tasks: [],
                                                                recoveryCandidates: [],
                                                                isUnavailable: false,
                                                                reconciliation: .init(roomID: roomID,
                                                                                      retainedEventIDs: [],
                                                                                      proposedPinRevision: nil,
                                                                                      isComplete: true)))
            }
            
            let observedRevision = NitroTaskIndex.pinRevision(info.pinnedEventIds)
            let scansAllPins = index.roomPinRevisions[info.id] != observedRevision
            let indexedEventIDSet = Set(indexedEventIDs)
            let eventIDs = scansAllPins
                ? info.pinnedEventIds
                : indexedEventIDs.filter { info.pinnedEventIds.contains($0) }
            let pinnedEvents = try await loadPinnedEvents(eventIDs: eventIDs,
                                                          scansAllPins: scansAllPins,
                                                          roomID: info.id,
                                                          room: room)
            var powerLevels = info.powerLevels
            if powerLevels == nil {
                powerLevels = try? await room.getPowerLevels()
            }
            let canSend = powerLevels?.canOwnUserSendMessage(message: .roomMessage) == true
            let canPin = powerLevels?.canOwnUserPinUnpin() == true
            let roomName = info.displayName ?? room.displayName() ?? info.id
            return .prepared(NitroTaskService.PreparedRoomTasks(room: room,
                                                                roomID: info.id,
                                                                roomName: roomName,
                                                                canSend: canSend,
                                                                canPin: canPin,
                                                                indexedEventIDs: indexedEventIDSet,
                                                                observedRevision: observedRevision,
                                                                scansAllPins: scansAllPins,
                                                                taskEvents: pinnedEvents.taskEvents,
                                                                recoveryCandidates: pinnedEvents.recoveryCandidates))
        } catch is CancellationError {
            return .loaded(NitroTaskService.LoadedRoomTasks(tasks: [],
                                                            recoveryCandidates: [],
                                                            isUnavailable: false,
                                                            reconciliation: .init(roomID: roomID,
                                                                                  retainedEventIDs: indexedEventIDs,
                                                                                  proposedPinRevision: index.roomPinRevisions[roomID],
                                                                                  isComplete: false)))
        } catch {
            MXLog.error("Failed loading Nitro tasks for \(roomID) with error: \(error)")
            return .loaded(NitroTaskService.LoadedRoomTasks(tasks: [],
                                                            recoveryCandidates: [],
                                                            isUnavailable: true,
                                                            reconciliation: .init(roomID: roomID,
                                                                                  retainedEventIDs: indexedEventIDs,
                                                                                  proposedPinRevision: index.roomPinRevisions[roomID],
                                                                                  isComplete: false)))
        }
    }
    
    @concurrent
    private static func loadPreparedTasks(_ rooms: [NitroTaskService.PreparedRoomTasks],
                                          ownUserID: String,
                                          session: Session,
                                          urlSession: URLSession,
                                          index: NitroTaskIndex,
                                          directoryResolution: NitroTaskDirectoryResolution) async -> NitroTaskService.LoadedPreparedTasks {
        let loadedTasks = await loadPreparedTaskJobs(rooms,
                                                     ownUserID: ownUserID,
                                                     session: session,
                                                     urlSession: urlSession,
                                                     directoryResolution: directoryResolution)
        var tasksByRoomIndex = [Int: [NitroTask]]()
        var directoryUpdates = [NitroTaskDirectoryUpdate]()
        var verifiedDirectoryKeys = Set<NitroTaskDirectoryKey>()
        for loadedTask in loadedTasks {
            tasksByRoomIndex[loadedTask.roomIndex, default: []].append(loadedTask.loadedTask.task)
            if let update = loadedTask.loadedTask.directoryUpdate {
                directoryUpdates.append(update)
            }
            if let key = loadedTask.loadedTask.verifiedDirectoryKey {
                verifiedDirectoryKeys.insert(key)
            }
        }
        var loadedRooms = [NitroTaskService.LoadedRoomTasks]()
        for (roomIndex, room) in rooms.enumerated() {
            let tasks = tasksByRoomIndex[roomIndex] ?? []
            var recoveryCandidates = room.recoveryCandidates
            for task in tasks where !task.stateIsAvailable {
                let candidate = NitroTaskService.RecoveryCandidate(roomID: room.roomID, eventID: task.id)
                if !recoveryCandidates.contains(candidate) {
                    recoveryCandidates.append(candidate)
                }
            }
            let retainedEventIDs = tasks.map(\.id) + room.recoveryCandidates
                .map(\.eventID)
                .filter { room.indexedEventIDs.contains($0) }
            do {
                try Task.checkCancellation()
                let proposedRevision = try await reconciledPinRevision(room.observedRevision,
                                                                       scansAllPins: room.scansAllPins,
                                                                       hasUnavailableEvents: !room.recoveryCandidates.isEmpty,
                                                                       room: room.room)
                loadedRooms.append(NitroTaskService.LoadedRoomTasks(tasks: tasks,
                                                                    recoveryCandidates: recoveryCandidates,
                                                                    isUnavailable: false,
                                                                    reconciliation: .init(roomID: room.roomID,
                                                                                          retainedEventIDs: retainedEventIDs,
                                                                                          proposedPinRevision: proposedRevision,
                                                                                          isComplete: proposedRevision != nil)))
            } catch is CancellationError {
                loadedRooms.append(NitroTaskService.LoadedRoomTasks(tasks: [],
                                                                    recoveryCandidates: [],
                                                                    isUnavailable: false,
                                                                    reconciliation: .init(roomID: room.roomID,
                                                                                          retainedEventIDs: Array(room.indexedEventIDs),
                                                                                          proposedPinRevision: index.roomPinRevisions[room.roomID],
                                                                                          isComplete: false)))
            } catch {
                MXLog.error("Failed reconciling Nitro tasks for \(room.roomID) with error: \(error)")
                loadedRooms.append(NitroTaskService.LoadedRoomTasks(tasks: [],
                                                                    recoveryCandidates: [],
                                                                    isUnavailable: true,
                                                                    reconciliation: .init(roomID: room.roomID,
                                                                                          retainedEventIDs: Array(room.indexedEventIDs),
                                                                                          proposedPinRevision: index.roomPinRevisions[room.roomID],
                                                                                          isComplete: false)))
            }
        }
        return .init(rooms: loadedRooms,
                     directoryUpdates: directoryUpdates,
                     verifiedDirectoryKeys: verifiedDirectoryKeys)
    }
    
    @concurrent
    private static func loadPreparedTaskJobs(_ rooms: [NitroTaskService.PreparedRoomTasks],
                                             ownUserID: String,
                                             session: Session,
                                             urlSession: URLSession,
                                             directoryResolution: NitroTaskDirectoryResolution) async -> [NitroTaskService.LoadedPreparedTask] {
        let taskLoadJobs = rooms.enumerated().flatMap { roomIndex, room in
            room.taskEvents.map { NitroTaskService.TaskLoadJob(roomIndex: roomIndex, taskEvent: $0) }
        }
        var jobs = taskLoadJobs.makeIterator()
        var loadedTasks = [NitroTaskService.LoadedPreparedTask]()
        await withTaskGroup(of: NitroTaskService.LoadedPreparedTask.self) { group in
            for _ in 0..<min(maximumConcurrentTaskLoads, taskLoadJobs.count) {
                guard !Task.isCancelled, let job = jobs.next() else { break }
                group.addTask {
                    await loadPreparedTask(job,
                                           room: rooms[job.roomIndex],
                                           ownUserID: ownUserID,
                                           session: session,
                                           urlSession: urlSession,
                                           directoryResolution: directoryResolution)
                }
            }
            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                loadedTasks.append(result)
                guard let job = jobs.next() else { continue }
                group.addTask {
                    await loadPreparedTask(job,
                                           room: rooms[job.roomIndex],
                                           ownUserID: ownUserID,
                                           session: session,
                                           urlSession: urlSession,
                                           directoryResolution: directoryResolution)
                }
            }
        }
        return loadedTasks
    }
    
    @concurrent
    private static func loadPreparedTask(_ job: NitroTaskService.TaskLoadJob,
                                         room: NitroTaskService.PreparedRoomTasks,
                                         ownUserID: String,
                                         session: Session,
                                         urlSession: URLSession,
                                         directoryResolution: NitroTaskDirectoryResolution) async -> NitroTaskService.LoadedPreparedTask {
        let key = NitroTaskDirectoryKey(roomID: room.roomID, taskEventID: job.taskEvent.eventID)
        let context = NitroTaskService.TaskLoadContext(roomID: room.roomID,
                                                       roomName: room.roomName,
                                                       ownUserID: ownUserID,
                                                       canSend: room.canSend,
                                                       canPin: room.canPin,
                                                       waitForDecryption: false,
                                                       room: room.room,
                                                       session: session,
                                                       urlSession: urlSession)
        let task = await loadTask(job.taskEvent,
                                  context: context,
                                  directoryHint: directoryResolution.hints[key],
                                  verificationRequired: directoryResolution.verificationRequired.contains(key))
        return NitroTaskService.LoadedPreparedTask(roomIndex: job.roomIndex, loadedTask: task)
    }
    
    @concurrent
    private static func loadPinnedEvents(eventIDs: [String],
                                         scansAllPins: Bool,
                                         roomID: String,
                                         room: MatrixRustSDK.Room) async throws -> NitroTaskService.LoadedPinnedEvents {
        guard !eventIDs.isEmpty else {
            return NitroTaskService.LoadedPinnedEvents(taskEvents: [], recoveryCandidates: [])
        }
        guard scansAllPins else {
            return try await loadIndexedEvents(eventIDs: eventIDs, roomID: roomID, room: room)
        }
        let timeline = try await room.timelineWithConfiguration(configuration: .init(focus: .pinnedEvents,
                                                                                     filter: .all,
                                                                                     internalIdPrefix: nil,
                                                                                     dateDividerMode: .daily,
                                                                                     trackReadReceipts: .disabled,
                                                                                     reportUtds: true))
        let timelineItems = try await NitroTaskService.initialTimelineItems(from: timeline)
        return NitroTaskService.loadedPinnedEvents(from: timelineItems, eventIDs: eventIDs, roomID: roomID)
    }
    
    @concurrent
    private static func reconciledPinRevision(_ observedRevision: String,
                                              scansAllPins: Bool,
                                              hasUnavailableEvents: Bool,
                                              room: MatrixRustSDK.Room) async throws -> String? {
        guard scansAllPins else { return observedRevision }
        guard !hasUnavailableEvents else { return nil }
        let latestInfo = try await room.roomInfo()
        return NitroTaskIndex.pinRevision(latestInfo.pinnedEventIds) == observedRevision ? observedRevision : nil
    }
    
    @concurrent
    private static func loadIndexedEvents(eventIDs: [String],
                                          roomID: String,
                                          room: MatrixRustSDK.Room) async throws -> NitroTaskService.LoadedPinnedEvents {
        var iterator = eventIDs.makeIterator()
        var loadedEvents = [String: NitroTaskService.LoadedIndexedEventResult]()
        
        try await withThrowingTaskGroup(of: NitroTaskService.LoadedIndexedEvent.self) { group in
            for _ in 0..<min(maximumConcurrentRoomLoads, eventIDs.count) {
                guard let eventID = iterator.next() else { break }
                group.addTask {
                    try await loadIndexedEvent(eventID: eventID, room: room)
                }
            }
            
            while let result = try await group.next() {
                loadedEvents[result.eventID] = result.result
                if let eventID = iterator.next() {
                    group.addTask {
                        try await loadIndexedEvent(eventID: eventID, room: room)
                    }
                }
            }
        }
        
        try Task.checkCancellation()
        var taskEvents = [NitroTaskEventParser.TaskEvent]()
        var recoveryCandidates = [NitroTaskService.RecoveryCandidate]()
        for eventID in eventIDs {
            switch loadedEvents[eventID] {
            case .eventJSON(.event(let originalJSON, let latestJSON)):
                if let taskEvent = NitroTaskEventParser.taskEvent(originalJSON: originalJSON,
                                                                  latestJSON: latestJSON,
                                                                  eventIDOverride: eventID) {
                    taskEvents.append(taskEvent)
                }
            case .eventJSON(.redacted):
                break
            case .eventJSON(.unableToDecrypt), .unavailable, .none:
                recoveryCandidates.append(.init(roomID: roomID, eventID: eventID))
            }
        }
        return NitroTaskService.LoadedPinnedEvents(taskEvents: taskEvents, recoveryCandidates: recoveryCandidates)
    }
    
    @concurrent
    private static func loadIndexedEvent(eventID: String,
                                         room: MatrixRustSDK.Room) async throws -> NitroTaskService.LoadedIndexedEvent {
        do {
            return try await NitroTaskService.LoadedIndexedEvent(eventID: eventID,
                                                                 result: .eventJSON(NitroTaskService.loadedEventJSON(eventID: eventID,
                                                                                                                     waitForDecryption: false,
                                                                                                                     room: room)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            MXLog.error("Failed loading indexed Nitro task candidate \(eventID) in \(room.id()) with error: \(error)")
            return NitroTaskService.LoadedIndexedEvent(eventID: eventID, result: .unavailable)
        }
    }
}
