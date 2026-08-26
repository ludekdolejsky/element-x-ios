//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

typealias NitroCatchUpScreenViewModelType = StateStoreViewModelV2<NitroCatchUpScreenViewState, NitroCatchUpScreenViewAction>

final class NitroCatchUpScreenViewModel: NitroCatchUpScreenViewModelType, NitroCatchUpScreenViewModelProtocol {
    private let roomID: String
    private let service: NitroCatchUpServiceProtocol
    private let actionsSubject = PassthroughSubject<NitroCatchUpScreenViewModelAction, Never>()
    
    var actionsPublisher: AnyPublisher<NitroCatchUpScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(roomID: String, roomName: String, service: NitroCatchUpServiceProtocol) {
        self.roomID = roomID
        self.service = service
        super.init(initialViewState: .init(roomName: roomName, bindings: .init()))
        
        service.operationsPublisher
            .map { operations in operations.first { $0.roomID == roomID } }
            .removeDuplicates()
            .sink { [weak self] operation in
                self?.state.operation = operation
            }
            .store(in: &cancellables)
        service.actionFailuresPublisher
            .filter { [weak self] operationID in
                self?.state.operation?.id == operationID
            }
            .sink { [weak self] _ in
                self?.state.bindings.alertInfo = .init(id: .requestFailed,
                                                       title: UntranslatedL10n.errorNitroCatchUpRequestFailedIos)
            }
            .store(in: &cancellables)
        service.restore()
    }
    
    override func process(viewAction: NitroCatchUpScreenViewAction) {
        switch viewAction {
        case .close:
            actionsSubject.send(.dismiss)
        case .start:
            let scope: NitroCatchUpScope = switch state.bindings.startPoint {
            case .lastRead: .lastRead
            case .date: .date(state.bindings.date)
            }
            if case .failure = service.start(roomID: roomID,
                                             roomName: state.roomName,
                                             scope: scope,
                                             mode: state.bindings.mode) {
                state.bindings.alertInfo = .init(id: .requestFailed,
                                                 title: UntranslatedL10n.errorNitroCatchUpRequestFailedIos)
            }
        case .cancel:
            guard let operation = state.operation else { return }
            service.cancel(operationID: operation.id)
        case .dismissResult:
            guard let operation = state.operation else { return }
            service.dismiss(operationID: operation.id)
        }
    }
}
