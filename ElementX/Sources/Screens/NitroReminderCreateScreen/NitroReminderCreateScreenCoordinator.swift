//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct NitroReminderCreateScreenCoordinatorParameters {
    let eventID: String
    let threadRootID: String?
    let roomProxy: JoinedRoomProxyProtocol
    let clientProxy: NitroClientProxyProtocol
    let reminderService: NitroReminderServiceProtocol
    let userIndicatorController: UserIndicatorControllerProtocol
}

enum NitroReminderCreateScreenCoordinatorAction {
    case dismiss
}

final class NitroReminderCreateScreenCoordinator: CoordinatorProtocol {
    private let viewModel: NitroReminderCreateScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    
    private let actionsSubject = PassthroughSubject<NitroReminderCreateScreenCoordinatorAction, Never>()
    var actionsPublisher: AnyPublisher<NitroReminderCreateScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: NitroReminderCreateScreenCoordinatorParameters) {
        viewModel = NitroReminderCreateScreenViewModel(eventID: parameters.eventID,
                                                       threadRootID: parameters.threadRootID,
                                                       roomProxy: parameters.roomProxy,
                                                       clientProxy: parameters.clientProxy,
                                                       reminderService: parameters.reminderService,
                                                       userIndicatorController: parameters.userIndicatorController)
    }
    
    func start() {
        viewModel.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .dismiss:
                    self?.actionsSubject.send(.dismiss)
                }
            }
            .store(in: &cancellables)
    }
    
    func toPresentable() -> AnyView {
        AnyView(NitroReminderCreateScreen(context: viewModel.context))
    }
}
