//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

struct NitroRoomWidgetsScreenCoordinatorParameters {
    let widgets: [NitroRoomWidget]
    let colorScheme: ColorScheme
    let driverFactory: () -> NitroRoomWidgetDriverProtocol?
}

enum NitroRoomWidgetsScreenCoordinatorAction {
    case dismiss
}

final class NitroRoomWidgetsScreenCoordinator: CoordinatorProtocol {
    private let viewModel: NitroRoomWidgetsScreenViewModelProtocol
    private let actionsSubject = PassthroughSubject<NitroRoomWidgetsScreenCoordinatorAction, Never>()
    private var cancellables = Set<AnyCancellable>()
    
    var actionsPublisher: AnyPublisher<NitroRoomWidgetsScreenCoordinatorAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(parameters: NitroRoomWidgetsScreenCoordinatorParameters) {
        viewModel = NitroRoomWidgetsScreenViewModel(widgets: parameters.widgets,
                                                    colorScheme: parameters.colorScheme,
                                                    driverFactory: parameters.driverFactory)
    }
    
    func start() {
        viewModel.actions
            .sink { [weak self] action in
                switch action {
                case .dismiss:
                    self?.actionsSubject.send(.dismiss)
                }
            }
            .store(in: &cancellables)
    }
    
    func stop() {
        viewModel.stop()
    }
    
    func toPresentable() -> AnyView {
        AnyView(NitroRoomWidgetsScreen(context: viewModel.context))
    }
}
