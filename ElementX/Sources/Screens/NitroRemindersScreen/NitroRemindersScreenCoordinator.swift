//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct NitroRemindersScreenCoordinatorParameters {
    let clientProxy: NitroClientProxyProtocol
    let reminderService: NitroReminderServiceProtocol
    let previewService: NitroReminderPreviewServiceProtocol
}

enum NitroRemindersScreenCoordinatorAction {
    case openReminder(roomID: String, eventID: String?, threadRootID: String?)
}

final class NitroRemindersScreenCoordinator: CoordinatorProtocol {
    private let viewModel: NitroRemindersScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    
    private let actionsSubject = PassthroughSubject<NitroRemindersScreenCoordinatorAction, Never>()
    var actionsPublisher: AnyPublisher<NitroRemindersScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: NitroRemindersScreenCoordinatorParameters) {
        viewModel = NitroRemindersScreenViewModel(clientProxy: parameters.clientProxy,
                                                  reminderService: parameters.reminderService,
                                                  previewService: parameters.previewService)
    }
    
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        viewModel.actionsPublisher
            .sink { [weak self] action in
                switch action {
                case .openReminder(let roomID, let eventID, let threadRootID):
                    self?.actionsSubject.send(.openReminder(roomID: roomID,
                                                            eventID: eventID,
                                                            threadRootID: threadRootID))
                }
            }
            .store(in: &cancellables)
    }
    
    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        cancellables.removeAll()
        viewModel.stop()
    }
    
    func refresh() {
        viewModel.refresh()
    }

    func show(room: NitroReminderRoom) {
        viewModel.show(room: room)
    }
    
    func toPresentable() -> AnyView {
        AnyView(NitroRemindersScreen(context: viewModel.context))
    }
}
