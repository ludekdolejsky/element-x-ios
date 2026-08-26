//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct NitroCatchUpScreenCoordinatorParameters {
    let roomID: String
    let roomName: String
    let service: NitroCatchUpServiceProtocol
}

enum NitroCatchUpScreenCoordinatorAction {
    case dismiss
}

final class NitroCatchUpScreenCoordinator: CoordinatorProtocol {
    private let viewModel: NitroCatchUpScreenViewModelProtocol
    private var cancellables = Set<AnyCancellable>()
    private let actionsSubject = PassthroughSubject<NitroCatchUpScreenCoordinatorAction, Never>()
    
    var actionsPublisher: AnyPublisher<NitroCatchUpScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: NitroCatchUpScreenCoordinatorParameters) {
        viewModel = NitroCatchUpScreenViewModel(roomID: parameters.roomID,
                                                roomName: parameters.roomName,
                                                service: parameters.service)
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
        AnyView(NitroCatchUpScreen(context: viewModel.context))
    }
}
