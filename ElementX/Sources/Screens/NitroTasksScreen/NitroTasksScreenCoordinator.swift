//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct NitroTasksScreenCoordinatorParameters {
    let taskService: NitroTaskServiceProtocol
}

enum NitroTasksScreenCoordinatorAction {
    case presentCreate(initialRoomID: String?)
    case presentReminders
    case presentReminder(NitroTask)
    case openTask(NitroTask)
    case openSource(NitroTask)
}

final class NitroTasksScreenCoordinator: CoordinatorProtocol {
    private let viewModel: NitroTasksScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject = PassthroughSubject<NitroTasksScreenCoordinatorAction, Never>()
    var actionsPublisher: AnyPublisher<NitroTasksScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: NitroTasksScreenCoordinatorParameters) {
        viewModel = NitroTasksScreenViewModel(taskService: parameters.taskService)
    }
    
    func start() {
        viewModel.actionsPublisher
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .presentCreate(let initialRoomID):
                    actionsSubject.send(.presentCreate(initialRoomID: initialRoomID))
                case .presentReminders:
                    actionsSubject.send(.presentReminders)
                case .presentReminder(let task):
                    actionsSubject.send(.presentReminder(task))
                case .openTask(let task):
                    actionsSubject.send(.openTask(task))
                case .openSource(let task):
                    actionsSubject.send(.openSource(task))
                }
            }
            .store(in: &cancellables)
    }
    
    func refresh() {
        viewModel.refresh()
    }
    
    func show(room: NitroTaskRoom) {
        viewModel.show(room: room)
    }
    
    func toPresentable() -> AnyView {
        AnyView(NitroTasksScreen(context: viewModel.context))
    }
}
