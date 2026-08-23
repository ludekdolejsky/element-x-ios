//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

protocol NitroTaskServiceProtocol {
    var updatesPublisher: AnyPublisher<NitroTaskServiceUpdate, Never> { get }
    var cachedTaskList: NitroTaskList? { get }
    
    func loadTasks() async -> Result<NitroTaskList, NitroTaskServiceError>
    func startPendingTaskRecovery()
    func loadRooms() async -> Result<[NitroTaskRoom], NitroTaskServiceError>
    func loadMembers(roomID: String) async -> Result<[NitroTaskMember], NitroTaskServiceError>
    func createTask(_ request: NitroTaskCreationRequest) async -> Result<NitroTask, NitroTaskServiceError>
    func updateTask(_ task: NitroTask,
                    state: NitroTaskState,
                    options: NitroTaskUpdateOptions) async -> Result<NitroTask, NitroTaskServiceError>
    func editTask(_ task: NitroTask, title: String, description: String) async -> Result<NitroTask, NitroTaskServiceError>
    func archiveTask(_ task: NitroTask) async -> Result<Void, NitroTaskServiceError>
}

extension NitroTaskServiceProtocol {
    func updateTask(_ task: NitroTask, state: NitroTaskState) async -> Result<NitroTask, NitroTaskServiceError> {
        await updateTask(task, state: state, options: .init())
    }
}
