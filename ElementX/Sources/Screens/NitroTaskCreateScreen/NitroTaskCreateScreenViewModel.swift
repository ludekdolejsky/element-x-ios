//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

typealias NitroTaskCreateScreenViewModelType = StateStoreViewModelV2<NitroTaskCreateScreenViewState, NitroTaskCreateScreenViewAction>

final class NitroTaskCreateScreenViewModel: NitroTaskCreateScreenViewModelType, NitroTaskCreateScreenViewModelProtocol, Identifiable {
    let id = UUID()
    
    private let taskService: NitroTaskServiceProtocol
    private let draft: NitroTaskCreateDraft
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private var loadTask: Task<Void, Never>?
    private var memberTask: Task<Void, Never>?
    private var memberTaskID: UUID?
    private var submitTask: Task<Void, Never>?
    
    private let actionsSubject = PassthroughSubject<NitroTaskCreateScreenViewModelAction, Never>()
    var actionsPublisher: AnyPublisher<NitroTaskCreateScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(taskService: NitroTaskServiceProtocol,
         draft: NitroTaskCreateDraft,
         userIndicatorController: UserIndicatorControllerProtocol) {
        self.taskService = taskService
        self.draft = draft
        self.userIndicatorController = userIndicatorController
        super.init(initialViewState: .init(fixedRoomID: draft.fixedRoomID,
                                           bindings: .init(title: draft.title,
                                                           description: draft.description,
                                                           selectedRoomID: draft.fixedRoomID ?? draft.initialRoomID,
                                                           selectedAssigneeID: draft.suggestedAssigneeID)))
    }
    
    override func process(viewAction: NitroTaskCreateScreenViewAction) {
        switch viewAction {
        case .load:
            guard !state.hasLoaded, loadTask == nil else { return }
            loadTask = Task { [weak self] in await self?.load() }
        case .selectRoom(let roomID):
            guard state.fixedRoomID == nil, state.bindings.selectedRoomID != roomID else { return }
            state.bindings.selectedRoomID = roomID
            state.bindings.selectedAssigneeID = nil
            loadMembers(roomID: roomID)
        case .cancel:
            loadTask?.cancel()
            memberTask?.cancel()
            submitTask?.cancel()
            actionsSubject.send(.dismiss(createdTask: nil))
        case .create:
            guard state.canSubmit, submitTask == nil else { return }
            submitTask = Task { [weak self] in await self?.submit() }
        }
    }
    
    private func load() async {
        state.isLoading = true
        defer {
            state.isLoading = false
            state.hasLoaded = true
            loadTask = nil
        }
        
        guard case let .success(rooms) = await taskService.loadRooms(), !Task.isCancelled else {
            if !Task.isCancelled {
                showFailure()
            }
            return
        }
        state.rooms = rooms
        
        if let fixedRoomID = state.fixedRoomID {
            guard rooms.contains(where: { $0.id == fixedRoomID }) else {
                state.bindings.selectedRoomID = nil
                showFailure()
                return
            }
            state.bindings.selectedRoomID = fixedRoomID
        } else if let selectedRoomID = state.bindings.selectedRoomID,
                  rooms.contains(where: { $0.id == selectedRoomID }) {
            state.bindings.selectedRoomID = selectedRoomID
        } else {
            state.bindings.selectedRoomID = rooms.first?.id
        }
        
        if let roomID = state.bindings.selectedRoomID {
            loadMembers(roomID: roomID)
        }
    }
    
    private func loadMembers(roomID: String) {
        memberTask?.cancel()
        let taskID = UUID()
        memberTaskID = taskID
        state.members = []
        state.isLoadingMembers = true
        memberTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if memberTaskID == taskID {
                    memberTask = nil
                    memberTaskID = nil
                    state.isLoadingMembers = false
                }
            }
            
            let result = await taskService.loadMembers(roomID: roomID)
            guard !Task.isCancelled,
                  memberTaskID == taskID,
                  state.bindings.selectedRoomID == roomID else {
                return
            }
            
            switch result {
            case .success(let members):
                state.members = members
                if let assigneeID = state.bindings.selectedAssigneeID,
                   !members.contains(where: { $0.id == assigneeID }) {
                    state.bindings.selectedAssigneeID = nil
                }
            case .failure(.cancelled):
                break
            case .failure:
                state.bindings.selectedAssigneeID = nil
                showFailure()
            }
        }
    }
    
    private func submit() async {
        defer { submitTask = nil }
        guard let roomID = state.bindings.selectedRoomID else { return }
        state.isSaving = true
        defer { state.isSaving = false }
        
        let request = NitroTaskCreationRequest(roomID: roomID,
                                               title: state.bindings.title,
                                               description: state.bindings.description,
                                               assigneeID: state.bindings.selectedAssigneeID,
                                               origin: draft.origin)
        switch await taskService.createTask(request) {
        case .success(let task):
            guard !Task.isCancelled else { return }
            userIndicatorController.submitIndicator(.init(type: .toast,
                                                          title: UntranslatedL10n.commonNitroTaskCreatedIos,
                                                          icon: \.check))
            actionsSubject.send(.dismiss(createdTask: task))
        case .failure(.cancelled):
            break
        case .failure:
            guard !Task.isCancelled else { return }
            showFailure()
        }
    }
    
    private func showFailure() {
        state.bindings.alertInfo = .init(id: .requestFailed,
                                         title: UntranslatedL10n.errorNitroTaskRequestFailedIos)
    }
}
