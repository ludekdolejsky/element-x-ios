//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

final class NitroTaskServiceMock: NitroTaskServiceProtocol {
    let updatesSubject = PassthroughSubject<NitroTaskServiceUpdate, Never>()
    var updatesPublisher: AnyPublisher<NitroTaskServiceUpdate, Never> {
        updatesSubject.eraseToAnyPublisher()
    }
    
    var cachedTaskList: NitroTaskList?
    
    var loadTasksReturnValue: Result<NitroTaskList, NitroTaskServiceError> = .success(.init(tasks: [], unavailableRoomCount: 0))
    var loadTasksClosure: (() async -> Result<NitroTaskList, NitroTaskServiceError>)?
    private(set) var loadTasksCallsCount = 0
    private(set) var startPendingTaskRecoveryCallsCount = 0
    
    var loadRoomsReturnValue: Result<[NitroTaskRoom], NitroTaskServiceError> = .success([])
    var loadRoomsClosure: (() async -> Result<[NitroTaskRoom], NitroTaskServiceError>)?
    private(set) var loadRoomsCallsCount = 0
    
    var loadMembersReturnValue: Result<[NitroTaskMember], NitroTaskServiceError> = .success([])
    var loadMembersClosure: ((String) async -> Result<[NitroTaskMember], NitroTaskServiceError>)?
    private(set) var loadMembersReceivedRoomIDs = [String]()
    
    var createTaskReturnValue: Result<NitroTask, NitroTaskServiceError> = .failure(.sendFailed)
    var createTaskClosure: ((NitroTaskCreationRequest) async -> Result<NitroTask, NitroTaskServiceError>)?
    private(set) var createTaskReceivedRequests = [NitroTaskCreationRequest]()
    
    var updateTaskReturnValue: Result<NitroTask, NitroTaskServiceError> = .failure(.sendFailed)
    var updateTaskClosure: ((NitroTask, NitroTaskState) async -> Result<NitroTask, NitroTaskServiceError>)?
    private(set) var updateTaskReceivedArguments = [(task: NitroTask, state: NitroTaskState, options: NitroTaskUpdateOptions)]()
    
    var editTaskReturnValue: Result<NitroTask, NitroTaskServiceError> = .failure(.sendFailed)
    var editTaskClosure: ((NitroTask, String, String) async -> Result<NitroTask, NitroTaskServiceError>)?
    private(set) var editTaskReceivedArguments = [(task: NitroTask, title: String, description: String)]()
    
    var archiveTaskReturnValue: Result<Void, NitroTaskServiceError> = .success(())
    var archiveTaskClosure: ((NitroTask) async -> Result<Void, NitroTaskServiceError>)?
    private(set) var archiveTaskReceivedTasks = [NitroTask]()
    
    func loadTasks() async -> Result<NitroTaskList, NitroTaskServiceError> {
        loadTasksCallsCount += 1
        return await loadTasksClosure?() ?? loadTasksReturnValue
    }
    
    func startPendingTaskRecovery() {
        startPendingTaskRecoveryCallsCount += 1
    }
    
    func loadRooms() async -> Result<[NitroTaskRoom], NitroTaskServiceError> {
        loadRoomsCallsCount += 1
        return await loadRoomsClosure?() ?? loadRoomsReturnValue
    }
    
    func loadMembers(roomID: String) async -> Result<[NitroTaskMember], NitroTaskServiceError> {
        loadMembersReceivedRoomIDs.append(roomID)
        return await loadMembersClosure?(roomID) ?? loadMembersReturnValue
    }
    
    func createTask(_ request: NitroTaskCreationRequest) async -> Result<NitroTask, NitroTaskServiceError> {
        createTaskReceivedRequests.append(request)
        return await createTaskClosure?(request) ?? createTaskReturnValue
    }
    
    func updateTask(_ task: NitroTask,
                    state: NitroTaskState,
                    options: NitroTaskUpdateOptions) async -> Result<NitroTask, NitroTaskServiceError> {
        updateTaskReceivedArguments.append((task, state, options))
        return await updateTaskClosure?(task, state) ?? updateTaskReturnValue
    }
    
    func editTask(_ task: NitroTask, title: String, description: String) async -> Result<NitroTask, NitroTaskServiceError> {
        editTaskReceivedArguments.append((task, title, description))
        return await editTaskClosure?(task, title, description) ?? editTaskReturnValue
    }
    
    func archiveTask(_ task: NitroTask) async -> Result<Void, NitroTaskServiceError> {
        archiveTaskReceivedTasks.append(task)
        return await archiveTaskClosure?(task) ?? archiveTaskReturnValue
    }
}
