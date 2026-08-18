//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct NitroTaskCreateScreenCoordinatorParameters {
    let taskService: NitroTaskServiceProtocol
    let draft: NitroTaskCreateDraft
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum NitroTaskCreateScreenCoordinatorAction {
    case dismiss(createdTask: NitroTask?)
}

final class NitroTaskCreateScreenCoordinator: CoordinatorProtocol {
    private let viewModel: NitroTaskCreateScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject = PassthroughSubject<NitroTaskCreateScreenCoordinatorAction, Never>()
    var actionsPublisher: AnyPublisher<NitroTaskCreateScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: NitroTaskCreateScreenCoordinatorParameters) {
        viewModel = NitroTaskCreateScreenViewModel(taskService: parameters.taskService,
                                                   draft: parameters.draft,
                                                   userIndicatorController: parameters.userIndicatorController)
    }
    
    func start() {
        viewModel.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .dismiss(let createdTask):
                    self?.actionsSubject.send(.dismiss(createdTask: createdTask))
                }
            }
            .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(NitroTaskCreateScreen(context: viewModel.context))
    }
}
