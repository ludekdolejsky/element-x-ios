//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK

final class NitroTaskService: NitroTaskServiceProtocol {
    private nonisolated enum InternalError: Error {
        case invalidResponse
        case permissionDenied
        case roomUnavailable
        case stateUnavailable
        case timedOut
    }
    
    private nonisolated struct LoadedRoomTasks: Sendable {
        let tasks: [NitroTask]
        let recoveryCandidates: [RecoveryCandidate]
        let isUnavailable: Bool
        let reconciliation: NitroTaskIndex.RoomReconciliation
    }
    
    private nonisolated struct LoadedTasks: Sendable {
        let list: NitroTaskList
        let recoveryCandidates: [RecoveryCandidate]
        let reconciliations: [NitroTaskIndex.RoomReconciliation]
    }
    
    private nonisolated struct LoadedPinnedEvents: Sendable {
        let taskEvents: [NitroTaskEventParser.TaskEvent]
        let recoveryCandidates: [RecoveryCandidate]
    }
    
    private nonisolated struct RecoveryCandidate: Equatable, Sendable {
        let roomID: String
        let eventID: String
    }
    
    private nonisolated enum RecoveryResult: Sendable {
        case resolved(RecoveryCandidate, NitroTask?)
        case failed(RecoveryCandidate)
        case cancelled(RecoveryCandidate)
    }
    
    private nonisolated struct LoadedTaskState: Sendable {
        let state: NitroTaskState
        let updatedDate: Date?
        let isAvailable: Bool
    }
    
    private nonisolated enum LoadedEventJSON: Sendable {
        case event(originalJSON: String?, latestJSON: String?)
        case redacted
        case unableToDecrypt
    }
    
    private nonisolated struct LoadedIndexedEvent: Sendable {
        let eventID: String
        let result: LoadedIndexedEventResult
    }
    
    private nonisolated enum LoadedIndexedEventResult: Sendable {
        case eventJSON(LoadedEventJSON)
        case unavailable
    }
    
    private nonisolated enum TaskIndexUpdate: Sendable {
        case add(roomID: String, eventID: String)
        case remove(roomID: String, eventID: String)
        case reconcile(initial: NitroTaskIndex, rooms: [NitroTaskIndex.RoomReconciliation])
        
        var mutation: NitroTaskIndex.Mutation? {
            switch self {
            case .add(let roomID, let eventID):
                .add(roomID: roomID, eventID: eventID)
            case .remove(let roomID, let eventID):
                .remove(roomID: roomID, eventID: eventID)
            case .reconcile:
                nil
            }
        }
        
        func reconciledIndex(from current: NitroTaskIndex?) -> NitroTaskIndex? {
            switch self {
            case .add, .remove:
                return current
            case .reconcile(let initial, let rooms):
                return initial.reconciled(with: current, rooms: rooms)
            }
        }
    }
    
    private nonisolated struct TaskIndexWriteState: Sendable {
        let index: NitroTaskIndex
        let pendingMutations: [NitroTaskIndex.Mutation]
    }
    
    private nonisolated static let maximumConcurrentRoomLoads = 4
    private nonisolated static let timelineTimeout: Duration = .seconds(15)
    private nonisolated static let relationsPageSize = 20
    
    private let client: ClientProtocol
    private let urlSession: URLSession
    private let updatesSubject = PassthroughSubject<NitroTaskServiceUpdate, Never>()
    private(set) var cachedTaskList: NitroTaskList?
    private var loadRequestID: UUID?
    private var recoveryCandidates = [RecoveryCandidate]()
    private var recoveryTask: Task<Void, Never>?
    private var recoveryTaskID: UUID?
    private var taskIndexUpdateTask: Task<TaskIndexWriteState?, Never>?
    private var taskIndexUpdateTaskID: UUID?
    private var taskIndexWriteState: TaskIndexWriteState?
    var updatesPublisher: AnyPublisher<NitroTaskServiceUpdate, Never> {
        updatesSubject.eraseToAnyPublisher()
    }
    
    init(client: ClientProtocol, urlSession: URLSession = .shared) {
        self.client = client
        self.urlSession = urlSession
    }
    
    func currentTaskIndexRevision() async -> String? {
        try? await client.accountData(eventType: NitroTaskEventParser.taskIndexEventType)
    }
    
    func loadTasks() async -> Result<NitroTaskList, NitroTaskServiceError> {
        cancelRecovery()
        let requestID = UUID()
        loadRequestID = requestID
        defer {
            if loadRequestID == requestID {
                loadRequestID = nil
            }
        }
        
        do {
            let session = try client.session()
            let ownUserID = try client.userId()
            let initialIndex = await loadTaskIndex() ?? .init(migrationComplete: false,
                                                              tasks: [],
                                                              roomPinRevisions: [:])
            let loadedTasks = try await Self.loadTasks(in: client.rooms(),
                                                       ownUserID: ownUserID,
                                                       session: session,
                                                       urlSession: urlSession,
                                                       index: initialIndex)
            guard !Task.isCancelled, loadRequestID == requestID else { return .failure(.cancelled) }
            await updateTaskIndex(.reconcile(initial: initialIndex, rooms: loadedTasks.reconciliations))
            guard !Task.isCancelled, loadRequestID == requestID else { return .failure(.cancelled) }
            recoveryCandidates = loadedTasks.recoveryCandidates
            cachedTaskList = loadedTasks.list
            return .success(loadedTasks.list)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            MXLog.error("Failed loading Nitro tasks with error: \(error)")
            return .failure(.requestFailed)
        }
    }
    
    func startPendingTaskRecovery() {
        guard recoveryTask == nil, !recoveryCandidates.isEmpty else { return }
        let taskID = UUID()
        let candidates = recoveryCandidates
        recoveryTaskID = taskID
        updatesSubject.send(.recoveryProgress(.init(pendingEventCount: candidates.count,
                                                    failedEventCount: 0)))
        recoveryTask = Task { [weak self] in
            await self?.recover(candidates, taskID: taskID)
        }
    }
    
    func loadRooms() async -> Result<[NitroTaskRoom], NitroTaskServiceError> {
        do {
            return try await .success(Self.loadEligibleRooms(client.rooms()))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            MXLog.error("Failed loading rooms eligible for Nitro tasks with error: \(error)")
            return .failure(.requestFailed)
        }
    }
    
    func loadMembers(roomID: String) async -> Result<[NitroTaskMember], NitroTaskServiceError> {
        do {
            guard let room = try client.getRoom(roomId: roomID), room.membership() == .joined else {
                return .failure(.roomUnavailable)
            }
            return try await .success(Self.loadMembers(in: room))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            MXLog.error("Failed loading Nitro task assignees for \(roomID) with error: \(error)")
            return .failure(.requestFailed)
        }
    }
    
    func createTask(_ request: NitroTaskCreationRequest) async -> Result<NitroTask, NitroTaskServiceError> {
        do {
            let task = try await Self.createTask(request, client: client)
            await updateTaskIndex(.add(roomID: task.roomID, eventID: task.id))
            cache(task)
            updatesSubject.send(.created(task))
            return .success(task)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch InternalError.permissionDenied {
            return .failure(.permissionDenied)
        } catch InternalError.roomUnavailable {
            return .failure(.roomUnavailable)
        } catch {
            MXLog.error("Failed creating a Nitro task in \(request.roomID) with error: \(error)")
            return .failure(.sendFailed)
        }
    }
    
    func updateTask(_ task: NitroTask,
                    state: NitroTaskState,
                    options: NitroTaskUpdateOptions) async -> Result<NitroTask, NitroTaskServiceError> {
        do {
            let updatedTask = try await Self.updateTask(task,
                                                        state: state,
                                                        options: options,
                                                        client: client)
            cache(updatedTask)
            updatesSubject.send(.updated(updatedTask))
            return .success(updatedTask)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch InternalError.permissionDenied {
            return .failure(.permissionDenied)
        } catch InternalError.roomUnavailable {
            return .failure(.roomUnavailable)
        } catch InternalError.stateUnavailable {
            return .failure(.stateUnavailable)
        } catch {
            MXLog.error("Failed updating Nitro task \(task.id) with error: \(error)")
            return .failure(.sendFailed)
        }
    }
    
    func editTask(_ task: NitroTask, title: String, description: String) async -> Result<NitroTask, NitroTaskServiceError> {
        do {
            let updatedTask = try await Self.editTask(task,
                                                      title: title,
                                                      description: description,
                                                      client: client)
            cache(updatedTask)
            updatesSubject.send(.updated(updatedTask))
            return .success(updatedTask)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch InternalError.invalidResponse {
            return .failure(.invalidTask)
        } catch InternalError.permissionDenied {
            return .failure(.permissionDenied)
        } catch InternalError.roomUnavailable {
            return .failure(.roomUnavailable)
        } catch {
            MXLog.error("Failed editing Nitro task \(task.id) with error: \(error)")
            return .failure(.sendFailed)
        }
    }
    
    func archiveTask(_ task: NitroTask) async -> Result<Void, NitroTaskServiceError> {
        do {
            try await Self.archiveTask(task, client: client)
            await updateTaskIndex(.remove(roomID: task.roomID, eventID: task.id))
            removeCachedTask(task)
            updatesSubject.send(.archived(task))
            return .success(())
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch InternalError.permissionDenied {
            return .failure(.permissionDenied)
        } catch InternalError.roomUnavailable {
            return .failure(.roomUnavailable)
        } catch {
            MXLog.error("Failed archiving Nitro task \(task.id) with error: \(error)")
            return .failure(.sendFailed)
        }
    }
    
    // MARK: - Loading
    
    @concurrent
    private static func loadTask(_ taskEvent: NitroTaskEventParser.TaskEvent,
                                 roomID: String,
                                 roomName: String,
                                 ownUserID: String,
                                 canSend: Bool,
                                 canPin: Bool,
                                 waitForDecryption: Bool,
                                 room: MatrixRustSDK.Room,
                                 session: Session,
                                 urlSession: URLSession) async -> NitroTask {
        let loadedState = await loadTaskState(taskEventID: taskEvent.eventID,
                                              initialState: taskEvent.metadata.initialState,
                                              waitForDecryption: waitForDecryption,
                                              room: room,
                                              session: session,
                                              urlSession: urlSession)
        let assigneeDisplayName: String? = if let assignee = loadedState.state.assignee {
            try? await room.memberDisplayName(userId: assignee)
        } else {
            nil
        }
        return NitroTask(id: taskEvent.eventID,
                         roomID: roomID,
                         roomName: roomName,
                         metadata: taskEvent.metadata,
                         state: loadedState.state,
                         stateIsAvailable: loadedState.isAvailable,
                         assigneeDisplayName: assigneeDisplayName,
                         updatedDate: loadedState.updatedDate,
                         canUpdate: canSend && loadedState.isAvailable,
                         canArchive: canPin,
                         canEditContent: canSend && taskEvent.senderID == ownUserID)
    }
    
    @concurrent
    private static func recover(_ candidate: RecoveryCandidate,
                                client: ClientProtocol,
                                session: Session,
                                urlSession: URLSession) async -> RecoveryResult {
        do {
            try Task.checkCancellation()
            guard let room = try client.getRoom(roomId: candidate.roomID), room.membership() == .joined else {
                return .resolved(candidate, nil)
            }
            let info = try await room.roomInfo()
            guard info.membership == .joined,
                  !info.isSpace,
                  info.successorRoom == nil,
                  info.pinnedEventIds.contains(candidate.eventID) else {
                return .resolved(candidate, nil)
            }
            
            let loadedEventJSON = try await loadedEventJSON(eventID: candidate.eventID,
                                                            waitForDecryption: true,
                                                            room: room)
            guard case let .event(originalJSON, latestJSON) = loadedEventJSON,
                  let taskEvent = NitroTaskEventParser.taskEvent(originalJSON: originalJSON,
                                                                 latestJSON: latestJSON,
                                                                 eventIDOverride: candidate.eventID) else {
                return .resolved(candidate, nil)
            }
            
            var powerLevels = info.powerLevels
            if powerLevels == nil {
                powerLevels = try? await room.getPowerLevels()
            }
            let task = try await loadTask(taskEvent,
                                          roomID: info.id,
                                          roomName: info.displayName ?? room.displayName() ?? info.id,
                                          ownUserID: client.userId(),
                                          canSend: powerLevels?.canOwnUserSendMessage(message: .roomMessage) == true,
                                          canPin: powerLevels?.canOwnUserPinUnpin() == true,
                                          waitForDecryption: true,
                                          room: room,
                                          session: session,
                                          urlSession: urlSession)
            return .resolved(candidate, task)
        } catch is CancellationError {
            return .cancelled(candidate)
        } catch {
            MXLog.error("Failed recovering Nitro task candidate \(candidate.eventID) in \(candidate.roomID) with error: \(error)")
            return .failed(candidate)
        }
    }
    
    @concurrent
    private static func loadEligibleRooms(_ rooms: [MatrixRustSDK.Room]) async throws -> [NitroTaskRoom] {
        try Task.checkCancellation()
        let joinedRooms = rooms.filter { $0.membership() == .joined && !$0.isSpace() }
        var iterator = joinedRooms.makeIterator()
        var taskRooms = [NitroTaskRoom]()
        
        await withTaskGroup(of: NitroTaskRoom?.self) { group in
            for _ in 0..<min(maximumConcurrentRoomLoads, joinedRooms.count) {
                guard let room = iterator.next() else { break }
                group.addTask { await eligibleTaskRoom(from: room) }
            }
            
            while let result = await group.next() {
                if let result {
                    taskRooms.append(result)
                }
                if let room = iterator.next() {
                    group.addTask { await eligibleTaskRoom(from: room) }
                }
            }
        }
        
        try Task.checkCancellation()
        return taskRooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    @concurrent
    private static func eligibleTaskRoom(from room: MatrixRustSDK.Room) async -> NitroTaskRoom? {
        guard !Task.isCancelled,
              let info = try? await room.roomInfo(),
              info.membership == .joined,
              !info.isSpace,
              info.successorRoom == nil else {
            return nil
        }
        var powerLevels = info.powerLevels
        if powerLevels == nil {
            powerLevels = try? await room.getPowerLevels()
        }
        guard let powerLevels,
              powerLevels.canOwnUserSendMessage(message: .roomMessage),
              powerLevels.canOwnUserPinUnpin() else {
            return nil
        }
        return NitroTaskRoom(id: info.id, name: info.displayName ?? room.displayName() ?? info.id)
    }
    
    @concurrent
    private static func loadMembers(in room: MatrixRustSDK.Room) async throws -> [NitroTaskMember] {
        try Task.checkCancellation()
        let iterator = try await room.members()
        var members = [NitroTaskMember]()
        
        while let chunk = iterator.nextChunk(chunkSize: 200) {
            try Task.checkCancellation()
            members.append(contentsOf: chunk.compactMap { member in
                guard member.membership == .join, !member.isServiceMember else { return nil }
                return NitroTaskMember(id: member.userId,
                                       displayName: member.displayName,
                                       avatarURL: member.avatarUrl.flatMap(URL.init(string:)))
            })
        }
        
        return members.sorted {
            let lhs = $0.displayName ?? $0.id
            let rhs = $1.displayName ?? $1.id
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }
    
    @concurrent
    private static func loadTaskState(taskEventID: String,
                                      initialState: NitroTaskState,
                                      waitForDecryption: Bool,
                                      room: MatrixRustSDK.Room,
                                      session: Session,
                                      urlSession: URLSession) async -> LoadedTaskState {
        do {
            var paginationToken: String?
            var seenPaginationTokens = Set<String>()
            
            repeat {
                try Task.checkCancellation()
                guard let url = relationsURL(homeserver: session.homeserverUrl,
                                             roomID: room.id(),
                                             eventID: taskEventID,
                                             from: paginationToken) else {
                    throw InternalError.invalidResponse
                }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                
                let (data, response) = try await urlSession.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let events = page["chunk"] as? [[String: Any]] else {
                    throw InternalError.invalidResponse
                }
                
                for event in events {
                    try Task.checkCancellation()
                    if let json = try? jsonString(from: event),
                       let update = NitroTaskEventParser.stateUpdate(from: json, taskEventID: taskEventID) {
                        return LoadedTaskState(state: update.state,
                                               updatedDate: update.updatedDate,
                                               isAvailable: true)
                    }
                    
                    guard event["type"] as? String == "m.room.encrypted",
                          let eventID = event["event_id"] as? String else {
                        continue
                    }
                    guard let update = try await loadEncryptedTaskStateUpdate(eventID: eventID,
                                                                              taskEventID: taskEventID,
                                                                              waitForDecryption: waitForDecryption,
                                                                              room: room) else {
                        continue
                    }
                    return LoadedTaskState(state: update.state,
                                           updatedDate: update.updatedDate,
                                           isAvailable: true)
                }
                
                paginationToken = page["next_batch"] as? String
                if let paginationToken, !seenPaginationTokens.insert(paginationToken).inserted {
                    throw InternalError.invalidResponse
                }
            } while paginationToken != nil
            
            return LoadedTaskState(state: initialState, updatedDate: nil, isAvailable: true)
        } catch is CancellationError {
            return LoadedTaskState(state: initialState, updatedDate: nil, isAvailable: false)
        } catch {
            MXLog.error("Failed resolving state for Nitro task \(taskEventID) with error: \(error)")
            return LoadedTaskState(state: initialState, updatedDate: nil, isAvailable: false)
        }
    }
    
    @concurrent
    private static func loadEncryptedTaskStateUpdate(eventID: String,
                                                     taskEventID: String,
                                                     waitForDecryption: Bool,
                                                     room: MatrixRustSDK.Room) async throws -> NitroTaskEventParser.StateUpdate? {
        let loadedEventJSON = try await loadedEventJSON(eventID: eventID,
                                                        waitForDecryption: waitForDecryption,
                                                        room: room)
        guard case let .event(originalJSON, latestJSON) = loadedEventJSON else {
            if case .unableToDecrypt = loadedEventJSON {
                throw InternalError.stateUnavailable
            }
            return nil
        }
        guard let json = originalJSON ?? latestJSON,
              NitroTaskEventParser.isRoomMessageEvent(json) else {
            throw InternalError.stateUnavailable
        }
        return NitroTaskEventParser.stateUpdate(originalJSON: originalJSON,
                                                latestJSON: latestJSON,
                                                taskEventID: taskEventID)
    }
    
    // MARK: - Mutations
    
    @concurrent
    private static func createTask(_ request: NitroTaskCreationRequest,
                                   client: ClientProtocol) async throws -> NitroTask {
        try Task.checkCancellation()
        let title = NitroTaskEventParser.normalizedTitle(request.title)
        let description = request.description.map(NitroTaskEventParser.normalizedDescription)
        guard !title.isEmpty else { throw InternalError.invalidResponse }
        guard let room = try client.getRoom(roomId: request.roomID), room.membership() == .joined else {
            throw InternalError.roomUnavailable
        }
        let info = try await room.roomInfo()
        guard !info.isSpace, info.successorRoom == nil else { throw InternalError.roomUnavailable }
        let powerLevels = if let powerLevels = info.powerLevels {
            powerLevels
        } else {
            try await room.getPowerLevels()
        }
        guard powerLevels.canOwnUserSendMessage(message: .roomMessage), powerLevels.canOwnUserPinUnpin() else {
            throw InternalError.permissionDenied
        }
        guard request.origin?.roomID == nil || request.origin?.roomID == request.roomID else {
            throw InternalError.invalidResponse
        }
        
        var assigneeDisplayName: String?
        if let assigneeID = request.assigneeID {
            let member = try await room.member(userId: assigneeID)
            guard member.membership == .join else { throw InternalError.invalidResponse }
            assigneeDisplayName = member.displayName
        }
        
        let batchID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let createdDate = Date()
        let initialState = NitroTaskState(status: .todo, assignee: request.assigneeID)
        let metadata = taskMetadataDictionary(title: title,
                                              description: description,
                                              batchID: batchID,
                                              createdDate: createdDate,
                                              initialState: request.assigneeID == nil ? nil : initialState,
                                              origin: request.origin)
        
        let sourceLine = request.origin?.permalink.map { "\nSource: \($0)" } ?? ""
        let formattedSource = request.origin?.permalink.map {
            "<br/><a href=\"\(htmlEscaped($0))\">Open source message</a>"
        } ?? ""
        let message = messageEventContentFromHtml(body: "Task: \(title)\(sourceLine)",
                                                  htmlBody: "<strong>Task:</strong> \(htmlEscaped(title))\(formattedSource)")
        let extraContent = try jsonString(from: [
            NitroTaskEventParser.c2mIgnoreContentKey: true,
            NitroTaskEventParser.taskContentKey: metadata
        ])
        let timeline = try await liveTimeline(in: room)
        let eventID = try await sendAndAwaitTaskEvent(message: message,
                                                      extraContent: extraContent,
                                                      batchID: batchID,
                                                      timeline: timeline)
        
        do {
            _ = try await timeline.pinEvent(eventId: eventID)
        } catch {
            try? await room.redact(eventId: eventID, reason: "Rolling back an incomplete task creation")
            throw error
        }
        
        let taskMetadata = NitroTaskMetadata(title: title,
                                             description: description?.isEmpty == false ? description : nil,
                                             batchID: batchID,
                                             sourceRoomID: request.origin?.roomID,
                                             sourceEventID: request.origin?.eventID,
                                             sourceThreadRootID: request.origin?.threadRootID,
                                             sourcePermalink: request.origin?.permalink,
                                             initialState: initialState,
                                             createdDate: createdDate)
        return NitroTask(id: eventID,
                         roomID: request.roomID,
                         roomName: info.displayName ?? room.displayName() ?? request.roomID,
                         metadata: taskMetadata,
                         state: initialState,
                         stateIsAvailable: true,
                         assigneeDisplayName: assigneeDisplayName,
                         updatedDate: nil,
                         canUpdate: true,
                         canArchive: true,
                         canEditContent: true)
    }
    
    @concurrent
    private static func updateTask(_ task: NitroTask,
                                   state: NitroTaskState,
                                   options: NitroTaskUpdateOptions,
                                   client: ClientProtocol) async throws -> NitroTask {
        try Task.checkCancellation()
        guard task.stateIsAvailable else { throw InternalError.stateUnavailable }
        guard task.canUpdate else { throw InternalError.permissionDenied }
        guard state != task.state || options.startWithCodex else { return task }
        guard let room = try client.getRoom(roomId: task.roomID), room.membership() == .joined else {
            throw InternalError.roomUnavailable
        }
        let info = try await room.roomInfo()
        guard info.pinnedEventIds.contains(task.id) else { throw InternalError.roomUnavailable }
        let powerLevels = if let powerLevels = info.powerLevels {
            powerLevels
        } else {
            try await room.getPowerLevels()
        }
        guard powerLevels.canOwnUserSendMessage(message: .roomMessage) else {
            throw InternalError.permissionDenied
        }
        
        var assigneeDisplayName: String?
        if let assigneeID = state.assignee {
            let member = try await room.member(userId: assigneeID)
            guard member.membership == .join else { throw InternalError.invalidResponse }
            assigneeDisplayName = member.displayName
        }
        
        let permalink = try await room.matrixToEventPermalink(eventId: task.id)
        let audit = await taskAudit(task: task,
                                    previousState: task.state,
                                    nextState: state,
                                    previousAssignee: formattedAssignee(task.state.assignee, room: room),
                                    nextAssignee: formattedAssignee(state.assignee, room: room),
                                    permalink: permalink,
                                    startedWithCodex: options.startWithCodex)
        let message = messageEventContentFromHtml(body: "\(audit.plain)\nOpen task: \(permalink)",
                                                  htmlBody: audit.html)
        let assignee: Any = if let assignee = state.assignee {
            assignee
        } else {
            NSNull()
        }
        let extraContent = taskUpdateExtraContent(task: task,
                                                  state: state,
                                                  assignee: assignee,
                                                  permalink: permalink,
                                                  options: options)
        let timeline = try await liveTimeline(in: room)
        _ = try await timeline.sendWithExtraContent(msg: message,
                                                    extraContentJson: jsonString(from: extraContent))
        
        var updatedTask = task
        updatedTask.state = state
        updatedTask.assigneeDisplayName = assigneeDisplayName
        updatedTask.updatedDate = Date()
        return updatedTask
    }
    
    @concurrent
    private static func archiveTask(_ task: NitroTask, client: ClientProtocol) async throws {
        try Task.checkCancellation()
        guard task.canArchive else { throw InternalError.permissionDenied }
        guard let room = try client.getRoom(roomId: task.roomID), room.membership() == .joined else {
            throw InternalError.roomUnavailable
        }
        let info = try await room.roomInfo()
        let powerLevels = if let powerLevels = info.powerLevels {
            powerLevels
        } else {
            try await room.getPowerLevels()
        }
        guard powerLevels.canOwnUserPinUnpin() else { throw InternalError.permissionDenied }
        guard info.pinnedEventIds.contains(task.id) else { return }
        let timeline = try await liveTimeline(in: room)
        _ = try await timeline.unpinEvent(eventId: task.id)
    }
    
    // MARK: - Timeline helpers
    
    @concurrent
    private static func liveTimeline(in room: MatrixRustSDK.Room) async throws -> Timeline {
        try await room.timelineWithConfiguration(configuration: .init(focus: .live(hideThreadedEvents: false),
                                                                      filter: .all,
                                                                      internalIdPrefix: nil,
                                                                      dateDividerMode: .daily,
                                                                      trackReadReceipts: .disabled,
                                                                      reportUtds: true))
    }
    
    @concurrent
    private static func initialTimelineItems(from timeline: Timeline) async throws -> [TimelineItem] {
        try await withThrowingTaskGroup(of: [TimelineItem].self) { group in
            group.addTask { try await observeInitialTimelineItems(from: timeline) }
            group.addTask {
                try await Task.sleep(for: timelineTimeout)
                throw InternalError.timedOut
            }
            guard let items = try await group.next() else { throw InternalError.invalidResponse }
            group.cancelAll()
            return items
        }
    }
    
    @concurrent
    private static func observeInitialTimelineItems(from timeline: Timeline) async throws -> [TimelineItem] {
        let (stream, continuation) = AsyncStream<[TimelineDiff]>.makeStream(bufferingPolicy: .bufferingNewest(20))
        let listenerHandle = await timeline.addListener(listener: SDKListener { continuation.yield($0) })
        defer {
            listenerHandle.cancel()
            continuation.finish()
        }
        
        var items = [TimelineItem]()
        for await diffs in stream {
            try Task.checkCancellation()
            apply(diffs, to: &items)
            if diffs.contains(where: {
                if case .reset = $0 {
                    true
                } else {
                    false
                }
            }) {
                return items
            }
        }
        throw InternalError.invalidResponse
    }
    
    @concurrent
    private static func loadedEventJSON(eventID: String,
                                        waitForDecryption: Bool,
                                        room: MatrixRustSDK.Room) async throws -> LoadedEventJSON {
        let timeline = try await room.timelineWithConfiguration(configuration: .init(focus: .event(eventId: eventID,
                                                                                                   numContextEvents: 0,
                                                                                                   threadMode: .automatic(hideThreadedEvents: false)),
                                                                                     filter: .all,
                                                                                     internalIdPrefix: nil,
                                                                                     dateDividerMode: .daily,
                                                                                     trackReadReceipts: .disabled,
                                                                                     reportUtds: true))
        return try await withThrowingTaskGroup(of: LoadedEventJSON.self) { group in
            group.addTask {
                try await observeEventJSON(eventID: eventID,
                                           waitForDecryption: waitForDecryption,
                                           timeline: timeline)
            }
            group.addTask {
                try await Task.sleep(for: timelineTimeout)
                throw InternalError.timedOut
            }
            guard let eventJSON = try await group.next() else { throw InternalError.invalidResponse }
            group.cancelAll()
            return eventJSON
        }
    }
    
    @concurrent
    private static func observeEventJSON(eventID: String,
                                         waitForDecryption: Bool,
                                         timeline: Timeline) async throws -> LoadedEventJSON {
        let (stream, continuation) = AsyncStream<[TimelineDiff]>.makeStream(bufferingPolicy: .bufferingNewest(20))
        let listenerHandle = await timeline.addListener(listener: SDKListener { continuation.yield($0) })
        defer {
            listenerHandle.cancel()
            continuation.finish()
        }
        
        var items = [TimelineItem]()
        var hasRetriedDecryption = false
        for await diffs in stream {
            try Task.checkCancellation()
            apply(diffs, to: &items)
            guard let event = items.compactMap({ $0.asEvent() }).first(where: { remoteEventID(for: $0) == eventID }) else {
                continue
            }
            let lazyProvider = event.lazyProvider
            let debugInfo = lazyProvider.debugInfo()
            if debugInfo.originalJson == nil, debugInfo.latestEditJson == nil {
                if isUnableToDecrypt(event) {
                    guard waitForDecryption else { return .unableToDecrypt }
                    if !hasRetriedDecryption {
                        timeline.retryDecryption(sessionIds: [])
                        hasRetriedDecryption = true
                    }
                    continue
                }
                return .redacted
            }
            return .event(originalJSON: debugInfo.originalJson,
                          latestJSON: lazyProvider.latestJson())
        }
        throw InternalError.invalidResponse
    }
    
    @concurrent
    private static func sendAndAwaitTaskEvent(message: RoomMessageEventContentWithoutRelation,
                                              extraContent: String,
                                              batchID: String,
                                              timeline: Timeline) async throws -> String {
        let (stream, continuation) = AsyncStream<[TimelineDiff]>.makeStream(bufferingPolicy: .bufferingNewest(50))
        let listenerHandle = await timeline.addListener(listener: SDKListener { continuation.yield($0) })
        defer {
            listenerHandle.cancel()
            continuation.finish()
        }
        
        _ = try await timeline.sendWithExtraContent(msg: message, extraContentJson: extraContent)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await observeSentTaskEvent(batchID: batchID, stream: stream) }
            group.addTask {
                try await Task.sleep(for: timelineTimeout)
                throw InternalError.timedOut
            }
            guard let eventID = try await group.next() else { throw InternalError.invalidResponse }
            group.cancelAll()
            return eventID
        }
    }
    
    @concurrent
    private static func observeSentTaskEvent(batchID: String,
                                             stream: AsyncStream<[TimelineDiff]>) async throws -> String {
        var items = [TimelineItem]()
        for await diffs in stream {
            try Task.checkCancellation()
            apply(diffs, to: &items)
            for event in items.compactMap({ $0.asEvent() }) {
                guard let eventID = remoteEventID(for: event),
                      let json = event.lazyProvider.latestJson(),
                      NitroTaskEventParser.taskEvent(from: json, eventIDOverride: eventID)?.metadata.batchID == batchID else {
                    continue
                }
                return eventID
            }
        }
        throw InternalError.invalidResponse
    }
    
    private nonisolated static func apply(_ diffs: [TimelineDiff], to items: inout [TimelineItem]) {
        for diff in diffs {
            switch diff {
            case .append(let newItems):
                items.append(contentsOf: newItems)
            case .clear:
                items.removeAll()
            case .insert(let index, let item):
                let index = Int(index)
                guard index <= items.count else { continue }
                items.insert(item, at: index)
            case .popBack:
                if !items.isEmpty {
                    items.removeLast()
                }
            case .popFront:
                if !items.isEmpty {
                    items.removeFirst()
                }
            case .pushBack(let item):
                items.append(item)
            case .pushFront(let item):
                items.insert(item, at: 0)
            case .remove(let index):
                let index = Int(index)
                guard index < items.count else { continue }
                items.remove(at: index)
            case .reset(let newItems):
                items = Array(newItems)
            case .set(let index, let item):
                let index = Int(index)
                guard index < items.count else { continue }
                items[index] = item
            case .truncate(let length):
                let length = Int(length)
                if length < items.count {
                    items.removeSubrange(length...)
                }
            }
        }
    }
    
    private nonisolated static func remoteEventID(for event: EventTimelineItem) -> String? {
        guard case let .eventId(eventID) = event.eventOrTransactionId else { return nil }
        return eventID
    }
    
    private nonisolated static func isUnableToDecrypt(_ event: EventTimelineItem) -> Bool {
        guard case .msgLike(let content) = event.content,
              case .unableToDecrypt = content.kind else {
            return false
        }
        return true
    }
    
    // MARK: - Formatting and transport
    
    private nonisolated static func relationsURL(homeserver: String,
                                                 roomID: String,
                                                 eventID: String,
                                                 from: String?) -> URL? {
        guard var components = URLComponents(string: homeserver),
              let roomID = encodedPathSegment(roomID),
              let eventID = encodedPathSegment(eventID) else {
            return nil
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/_matrix/client/v1/rooms/\(roomID)/relations/\(eventID)/m.reference"
        components.queryItems = [
            .init(name: "dir", value: "b"),
            .init(name: "limit", value: String(relationsPageSize))
        ]
        if let from {
            components.queryItems?.append(.init(name: "from", value: from))
        }
        return components.url
    }
    
    private nonisolated static func encodedPathSegment(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))
    }
    
    private nonisolated static func jsonString(from value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let string = String(data: data, encoding: .utf8) else { throw InternalError.invalidResponse }
        return string
    }
    
    private nonisolated static func taskStateDictionary(_ state: NitroTaskState) -> [String: Any] {
        let assignee: Any = if let assignee = state.assignee {
            assignee
        } else {
            NSNull()
        }
        return ["status": state.status.rawValue, "assignee": assignee]
    }
    
    private nonisolated static func taskMetadataDictionary(title: String,
                                                           description: String?,
                                                           batchID: String,
                                                           createdDate: Date,
                                                           initialState: NitroTaskState?,
                                                           origin: NitroTaskOrigin?) -> [String: Any] {
        var metadata: [String: Any] = [
            "version": 1,
            "title": title,
            "batch_id": batchID,
            "created_ts": Int64(createdDate.timeIntervalSince1970 * 1000)
        ]
        if let description, !description.isEmpty {
            metadata["description"] = description
        }
        if let origin {
            metadata["source_room_id"] = origin.roomID
            metadata["source_event_id"] = origin.eventID
            metadata["source_thread_root_id"] = origin.threadRootID
            metadata["source_permalink"] = origin.permalink
        }
        if let initialState {
            metadata["initial_state"] = taskStateDictionary(initialState)
        }
        return metadata
    }
    
    private nonisolated static func taskMetadataDictionary(_ metadata: NitroTaskMetadata) -> [String: Any] {
        var content: [String: Any] = [
            "version": 1,
            "title": metadata.title,
            "batch_id": metadata.batchID,
            "created_ts": Int64(metadata.createdDate.timeIntervalSince1970 * 1000),
            "initial_state": taskStateDictionary(metadata.initialState)
        ]
        content["description"] = metadata.description
        content["source_room_id"] = metadata.sourceRoomID
        content["source_event_id"] = metadata.sourceEventID
        content["source_thread_root_id"] = metadata.sourceThreadRootID
        content["source_permalink"] = metadata.sourcePermalink
        return content
    }
    
    private nonisolated static func taskUpdateExtraContent(task: NitroTask,
                                                           state: NitroTaskState,
                                                           assignee: Any,
                                                           permalink: String,
                                                           options: NitroTaskUpdateOptions) -> [String: Any] {
        var content: [String: Any] = [
            "m.mentions": [String: Any](),
            "m.relates_to": [
                "rel_type": "m.reference",
                "event_id": task.id,
                "m.in_reply_to": ["event_id": task.id]
            ],
            NitroTaskEventParser.taskUpdateContentKey: [
                "version": 1,
                "status": state.status.rawValue,
                "assignee": assignee
            ]
        ]
        if options.startWithCodex {
            content[NitroTaskEventParser.c2mStartTaskContentKey] = [
                "version": 1,
                "task_event_id": task.id,
                "task_permalink": permalink,
                "task": taskMetadataDictionary(task.metadata)
            ]
        } else {
            content[NitroTaskEventParser.c2mIgnoreContentKey] = true
        }
        return content
    }
    
    private nonisolated static func taskAudit(task: NitroTask,
                                              previousState: NitroTaskState,
                                              nextState: NitroTaskState,
                                              previousAssignee: String,
                                              nextAssignee: String,
                                              permalink: String,
                                              startedWithCodex: Bool) -> (plain: String, html: String) {
        var plainChanges = [String]()
        var htmlChanges = [String]()
        if previousState.status != nextState.status {
            let previous = statusTitle(previousState.status)
            let next = statusTitle(nextState.status)
            plainChanges.append("Status: \(previous) → \(next)")
            htmlChanges.append("Status: \(htmlEscaped(previous)) → \(htmlEscaped(next))")
        }
        if previousState.assignee != nextState.assignee {
            plainChanges.append("Assignee: \(previousAssignee) → \(nextAssignee)")
            htmlChanges.append("Assignee: \(htmlEscaped(previousAssignee)) → \(htmlEscaped(nextAssignee))")
        }
        if startedWithCodex {
            plainChanges.append("Codex: requested")
            htmlChanges.append("Codex: requested")
        }
        
        let plain = "Task “\(task.metadata.title)” updated — \(plainChanges.joined(separator: "; "))."
        let html = "Task <a href=\"\(htmlEscaped(permalink))\"><strong>\(htmlEscaped(task.metadata.title))</strong></a> updated — \(htmlChanges.joined(separator: "; "))."
        return (plain, html)
    }
    
    private nonisolated static func formattedAssignee(_ userID: String?, room: MatrixRustSDK.Room) async -> String {
        guard let userID else { return "Unassigned" }
        let displayName = try? await room.memberDisplayName(userId: userID)
        guard let displayName, !displayName.isEmpty, displayName != userID else { return userID }
        return "\(displayName) (\(userID))"
    }
    
    private nonisolated static func statusTitle(_ status: NitroTaskStatus) -> String {
        switch status {
        case .todo: "To do"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }
    
    private nonisolated static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private extension NitroTaskService {
    @concurrent
    private static func loadTasks(in rooms: [MatrixRustSDK.Room],
                                  ownUserID: String,
                                  session: Session,
                                  urlSession: URLSession,
                                  index: NitroTaskIndex) async throws -> LoadedTasks {
        try Task.checkCancellation()
        let joinedRooms = rooms.filter { $0.membership() == .joined && !$0.isSpace() }
        var iterator = joinedRooms.makeIterator()
        var loadedRooms = [LoadedRoomTasks]()
        
        await withTaskGroup(of: LoadedRoomTasks.self) { group in
            for _ in 0..<min(maximumConcurrentRoomLoads, joinedRooms.count) {
                guard let room = iterator.next() else { break }
                group.addTask {
                    await loadTasks(in: room,
                                    ownUserID: ownUserID,
                                    session: session,
                                    urlSession: urlSession,
                                    index: index)
                }
            }
            
            while let result = await group.next() {
                loadedRooms.append(result)
                if let room = iterator.next() {
                    group.addTask {
                        await loadTasks(in: room,
                                        ownUserID: ownUserID,
                                        session: session,
                                        urlSession: urlSession,
                                        index: index)
                    }
                }
            }
        }
        
        try Task.checkCancellation()
        let tasks = loadedRooms
            .flatMap(\.tasks)
            .sorted { lhs, rhs in
                lhs.metadata.createdDate != rhs.metadata.createdDate
                    ? lhs.metadata.createdDate > rhs.metadata.createdDate
                    : lhs.id < rhs.id
            }
        let recoveryCandidates = loadedRooms.flatMap(\.recoveryCandidates)
        return LoadedTasks(list: .init(tasks: tasks,
                                       unavailableRoomCount: loadedRooms.count(where: \.isUnavailable),
                                       pendingEventCount: recoveryCandidates.count),
                           recoveryCandidates: recoveryCandidates,
                           reconciliations: loadedRooms.map(\.reconciliation))
    }
    
    @concurrent
    private static func loadTasks(in room: MatrixRustSDK.Room,
                                  ownUserID: String,
                                  session: Session,
                                  urlSession: URLSession,
                                  index: NitroTaskIndex) async -> LoadedRoomTasks {
        let roomID = room.id()
        let indexedEventIDs = index.eventIDs(in: roomID)
        do {
            try Task.checkCancellation()
            let info = try await room.roomInfo()
            guard info.membership == .joined,
                  !info.isSpace,
                  info.successorRoom == nil else {
                return LoadedRoomTasks(tasks: [],
                                       recoveryCandidates: [],
                                       isUnavailable: false,
                                       reconciliation: .init(roomID: roomID,
                                                             retainedEventIDs: [],
                                                             proposedPinRevision: nil,
                                                             isComplete: true))
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
            let eventRecoveryCandidates = pinnedEvents.recoveryCandidates
            var recoveryCandidates = pinnedEvents.recoveryCandidates
            
            var powerLevels = info.powerLevels
            if powerLevels == nil {
                powerLevels = try? await room.getPowerLevels()
            }
            let canSend = powerLevels?.canOwnUserSendMessage(message: .roomMessage) == true
            let canPin = powerLevels?.canOwnUserPinUnpin() == true
            let roomName = info.displayName ?? room.displayName() ?? info.id
            var tasks = [NitroTask]()
            
            for taskEvent in pinnedEvents.taskEvents {
                try Task.checkCancellation()
                let task = await loadTask(taskEvent,
                                          roomID: info.id,
                                          roomName: roomName,
                                          ownUserID: ownUserID,
                                          canSend: canSend,
                                          canPin: canPin,
                                          waitForDecryption: false,
                                          room: room,
                                          session: session,
                                          urlSession: urlSession)
                tasks.append(task)
                if !task.stateIsAvailable {
                    let candidate = RecoveryCandidate(roomID: info.id, eventID: task.id)
                    if !recoveryCandidates.contains(candidate) {
                        recoveryCandidates.append(candidate)
                    }
                }
            }
            let retainedEventIDs = tasks.map(\.id) + eventRecoveryCandidates
                .map(\.eventID)
                .filter { indexedEventIDSet.contains($0) }
            let proposedRevision = try await reconciledPinRevision(observedRevision,
                                                                   scansAllPins: scansAllPins,
                                                                   hasUnavailableEvents: !eventRecoveryCandidates.isEmpty,
                                                                   room: room)
            
            return LoadedRoomTasks(tasks: tasks,
                                   recoveryCandidates: recoveryCandidates,
                                   isUnavailable: false,
                                   reconciliation: .init(roomID: info.id,
                                                         retainedEventIDs: retainedEventIDs,
                                                         proposedPinRevision: proposedRevision,
                                                         isComplete: proposedRevision != nil))
        } catch is CancellationError {
            return LoadedRoomTasks(tasks: [],
                                   recoveryCandidates: [],
                                   isUnavailable: false,
                                   reconciliation: .init(roomID: roomID,
                                                         retainedEventIDs: indexedEventIDs,
                                                         proposedPinRevision: index.roomPinRevisions[roomID],
                                                         isComplete: false))
        } catch {
            MXLog.error("Failed loading Nitro tasks for \(roomID) with error: \(error)")
            return LoadedRoomTasks(tasks: [],
                                   recoveryCandidates: [],
                                   isUnavailable: true,
                                   reconciliation: .init(roomID: roomID,
                                                         retainedEventIDs: indexedEventIDs,
                                                         proposedPinRevision: index.roomPinRevisions[roomID],
                                                         isComplete: false))
        }
    }
    
    @concurrent
    private static func loadPinnedEvents(eventIDs: [String],
                                         scansAllPins: Bool,
                                         roomID: String,
                                         room: MatrixRustSDK.Room) async throws -> LoadedPinnedEvents {
        guard !eventIDs.isEmpty else {
            return LoadedPinnedEvents(taskEvents: [], recoveryCandidates: [])
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
        let timelineItems = try await initialTimelineItems(from: timeline)
        return loadedPinnedEvents(from: timelineItems, eventIDs: eventIDs, roomID: roomID)
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
                                          room: MatrixRustSDK.Room) async throws -> LoadedPinnedEvents {
        var iterator = eventIDs.makeIterator()
        var loadedEvents = [String: LoadedIndexedEventResult]()
        
        try await withThrowingTaskGroup(of: LoadedIndexedEvent.self) { group in
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
        var recoveryCandidates = [RecoveryCandidate]()
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
        return LoadedPinnedEvents(taskEvents: taskEvents, recoveryCandidates: recoveryCandidates)
    }
    
    @concurrent
    private static func loadIndexedEvent(eventID: String,
                                         room: MatrixRustSDK.Room) async throws -> LoadedIndexedEvent {
        do {
            return try await LoadedIndexedEvent(eventID: eventID,
                                                result: .eventJSON(loadedEventJSON(eventID: eventID,
                                                                                   waitForDecryption: false,
                                                                                   room: room)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            MXLog.error("Failed loading indexed Nitro task candidate \(eventID) in \(room.id()) with error: \(error)")
            return LoadedIndexedEvent(eventID: eventID, result: .unavailable)
        }
    }
    
    @concurrent
    private static func editTask(_ task: NitroTask,
                                 title: String,
                                 description: String,
                                 client: ClientProtocol) async throws -> NitroTask {
        try Task.checkCancellation()
        let title = NitroTaskEventParser.normalizedTitle(title)
        let description = NitroTaskEventParser.normalizedDescription(description)
        guard !title.isEmpty else { throw InternalError.invalidResponse }
        guard task.canEditContent else { throw InternalError.permissionDenied }
        guard let room = try client.getRoom(roomId: task.roomID), room.membership() == .joined else {
            throw InternalError.roomUnavailable
        }
        let info = try await room.roomInfo()
        guard info.pinnedEventIds.contains(task.id) else { throw InternalError.roomUnavailable }
        let powerLevels = if let powerLevels = info.powerLevels {
            powerLevels
        } else {
            try await room.getPowerLevels()
        }
        guard powerLevels.canOwnUserSendMessage(message: .roomMessage) else {
            throw InternalError.permissionDenied
        }
        
        let origin: NitroTaskOrigin? = if let sourceRoomID = task.metadata.sourceRoomID,
                                          let sourceEventID = task.metadata.sourceEventID {
            .init(roomID: sourceRoomID,
                  eventID: sourceEventID,
                  threadRootID: task.metadata.sourceThreadRootID,
                  permalink: task.metadata.sourcePermalink)
        } else {
            nil
        }
        let metadata = taskMetadataDictionary(title: title,
                                              description: description,
                                              batchID: task.metadata.batchID,
                                              createdDate: task.metadata.createdDate,
                                              initialState: task.metadata.initialState,
                                              origin: origin)
        let sourceLine = task.metadata.sourcePermalink.map { "\nSource: \($0)" } ?? ""
        let formattedSource = task.metadata.sourcePermalink.map {
            "<br/><a href=\"\(htmlEscaped($0))\">Open source message</a>"
        } ?? ""
        let newContent: [String: Any] = [
            "msgtype": "m.text",
            "body": "Task: \(title)\(sourceLine)",
            "format": "org.matrix.custom.html",
            "formatted_body": "<strong>Task:</strong> \(htmlEscaped(title))\(formattedSource)",
            NitroTaskEventParser.c2mIgnoreContentKey: true,
            NitroTaskEventParser.taskContentKey: metadata
        ]
        let message = messageEventContentFromHtml(body: "* Task: \(title)\(sourceLine)",
                                                  htmlBody: "* <strong>Task:</strong> \(htmlEscaped(title))\(formattedSource)")
        let extraContent = try jsonString(from: [
            "m.new_content": newContent,
            "m.relates_to": [
                "rel_type": "m.replace",
                "event_id": task.id
            ],
            "m.mentions": [String: Any](),
            NitroTaskEventParser.c2mIgnoreContentKey: true
        ])
        let timeline = try await liveTimeline(in: room)
        _ = try await timeline.sendWithExtraContent(msg: message, extraContentJson: extraContent)
        
        var updatedTask = task
        updatedTask.metadata = NitroTaskMetadata(title: title,
                                                 description: description.isEmpty ? nil : description,
                                                 batchID: task.metadata.batchID,
                                                 sourceRoomID: task.metadata.sourceRoomID,
                                                 sourceEventID: task.metadata.sourceEventID,
                                                 sourceThreadRootID: task.metadata.sourceThreadRootID,
                                                 sourcePermalink: task.metadata.sourcePermalink,
                                                 initialState: task.metadata.initialState,
                                                 createdDate: task.metadata.createdDate)
        updatedTask.updatedDate = Date()
        return updatedTask
    }
    
    private nonisolated static func loadedPinnedEvents(from timelineItems: [TimelineItem],
                                                       eventIDs: [String],
                                                       roomID: String) -> LoadedPinnedEvents {
        let pinnedEventIDs = Set(eventIDs)
        var eventsByID = [String: EventTimelineItem]()
        for event in timelineItems.compactMap({ $0.asEvent() }) {
            guard let eventID = remoteEventID(for: event), pinnedEventIDs.contains(eventID) else { continue }
            eventsByID[eventID] = event
        }
        
        var taskEvents = [NitroTaskEventParser.TaskEvent]()
        var recoveryCandidates = [RecoveryCandidate]()
        for eventID in eventIDs {
            guard let event = eventsByID[eventID] else {
                recoveryCandidates.append(.init(roomID: roomID, eventID: eventID))
                continue
            }
            let lazyProvider = event.lazyProvider
            let debugInfo = lazyProvider.debugInfo()
            if let taskEvent = NitroTaskEventParser.taskEvent(originalJSON: debugInfo.originalJson,
                                                              latestJSON: lazyProvider.latestJson(),
                                                              eventIDOverride: eventID) {
                taskEvents.append(taskEvent)
            } else if isUnableToDecrypt(event) {
                recoveryCandidates.append(.init(roomID: roomID, eventID: eventID))
            }
        }
        return LoadedPinnedEvents(taskEvents: taskEvents, recoveryCandidates: recoveryCandidates)
    }
    
    private func recover(_ candidates: [RecoveryCandidate], taskID: UUID) async {
        let session: Session
        do {
            session = try client.session()
        } catch {
            MXLog.error("Failed starting Nitro task recovery with error: \(error)")
            finishRecovery(taskID: taskID, failedCandidates: candidates)
            return
        }
        
        var iterator = candidates.makeIterator()
        var pendingEventCount = candidates.count
        var failedCandidates = [RecoveryCandidate]()
        let client = client
        let urlSession = urlSession
        
        await withTaskGroup(of: RecoveryResult.self) { group in
            for _ in 0..<min(Self.maximumConcurrentRoomLoads, candidates.count) {
                guard let candidate = iterator.next() else { break }
                group.addTask {
                    await Self.recover(candidate,
                                       client: client,
                                       session: session,
                                       urlSession: urlSession)
                }
            }
            
            while let result = await group.next() {
                guard !Task.isCancelled, recoveryTaskID == taskID else {
                    group.cancelAll()
                    return
                }
                
                pendingEventCount -= 1
                switch result {
                case .resolved(let candidate, let task):
                    if let task {
                        cache(task)
                        updatesSubject.send(.recovered(task))
                        if !task.stateIsAvailable {
                            failedCandidates.append(candidate)
                        }
                    }
                case .failed(let candidate), .cancelled(let candidate):
                    failedCandidates.append(candidate)
                }
                updateCachedPendingEventCount(pendingEventCount)
                updatesSubject.send(.recoveryProgress(.init(pendingEventCount: pendingEventCount,
                                                            failedEventCount: failedCandidates.count)))
                
                if let candidate = iterator.next() {
                    group.addTask {
                        await Self.recover(candidate,
                                           client: client,
                                           session: session,
                                           urlSession: urlSession)
                    }
                }
            }
        }
        
        finishRecovery(taskID: taskID, failedCandidates: failedCandidates)
    }
    
    private func finishRecovery(taskID: UUID, failedCandidates: [RecoveryCandidate]) {
        guard recoveryTaskID == taskID else { return }
        recoveryCandidates = failedCandidates
        recoveryTask = nil
        recoveryTaskID = nil
        updateCachedPendingEventCount(0)
        updatesSubject.send(.recoveryProgress(.init(pendingEventCount: 0,
                                                    failedEventCount: failedCandidates.count)))
    }
    
    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryTaskID = nil
        recoveryCandidates.removeAll()
    }
    
    private func loadTaskIndex() async -> NitroTaskIndex? {
        do {
            return try await NitroTaskIndex.decode(client.accountData(eventType: NitroTaskEventParser.taskIndexEventType))
        } catch is CancellationError {
            return nil
        } catch {
            MXLog.error("Failed loading the Nitro task index with error: \(error)")
            return nil
        }
    }
    
    private func updateTaskIndex(_ update: TaskIndexUpdate) async {
        let previousTask = taskIndexUpdateTask
        let taskID = UUID()
        let client = client
        let cachedState = taskIndexWriteState
        let task = Task {
            let previousState = if let previousTask {
                await previousTask.value
            } else {
                cachedState
            }
            do {
                let currentJSON = try await client.accountData(eventType: NitroTaskEventParser.taskIndexEventType)
                let current = NitroTaskIndex.decode(currentJSON)
                var pendingMutations = previousState?.pendingMutations ?? []
                if previousState?.index == current {
                    pendingMutations.removeAll()
                }
                if let mutation = update.mutation {
                    pendingMutations.removeAll { $0.targetsSameEntry(as: mutation) }
                    pendingMutations.append(mutation)
                }
                let rebasedIndex = NitroTaskIndex.replaying(pendingMutations, on: current)
                guard let next = update.reconciledIndex(from: rebasedIndex) else { return previousState }
                try await client.setAccountData(eventType: NitroTaskEventParser.taskIndexEventType,
                                                content: next.jsonString())
                return TaskIndexWriteState(index: next, pendingMutations: pendingMutations)
            } catch {
                MXLog.error("Failed updating the Nitro task index with error: \(error)")
                return previousState
            }
        }
        taskIndexUpdateTask = task
        taskIndexUpdateTaskID = taskID
        let updatedState = await task.value
        if taskIndexUpdateTaskID == taskID {
            if let updatedState {
                taskIndexWriteState = updatedState
            }
            taskIndexUpdateTask = nil
            taskIndexUpdateTaskID = nil
        }
    }
    
    private func cache(_ task: NitroTask) {
        guard let cachedTaskList else { return }
        var tasks = cachedTaskList.tasks
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        self.cachedTaskList = NitroTaskList(tasks: Self.sortedTasks(tasks),
                                            unavailableRoomCount: cachedTaskList.unavailableRoomCount,
                                            pendingEventCount: cachedTaskList.pendingEventCount)
    }
    
    private func removeCachedTask(_ task: NitroTask) {
        guard let cachedTaskList else { return }
        self.cachedTaskList = NitroTaskList(tasks: cachedTaskList.tasks.filter { $0.id != task.id },
                                            unavailableRoomCount: cachedTaskList.unavailableRoomCount,
                                            pendingEventCount: cachedTaskList.pendingEventCount)
    }
    
    private func updateCachedPendingEventCount(_ pendingEventCount: Int) {
        guard let cachedTaskList else { return }
        self.cachedTaskList = NitroTaskList(tasks: cachedTaskList.tasks,
                                            unavailableRoomCount: cachedTaskList.unavailableRoomCount,
                                            pendingEventCount: pendingEventCount)
    }
    
    private nonisolated static func sortedTasks(_ tasks: [NitroTask]) -> [NitroTask] {
        tasks.sorted { lhs, rhs in
            lhs.metadata.createdDate != rhs.metadata.createdDate
                ? lhs.metadata.createdDate > rhs.metadata.createdDate
                : lhs.id < rhs.id
        }
    }
}
