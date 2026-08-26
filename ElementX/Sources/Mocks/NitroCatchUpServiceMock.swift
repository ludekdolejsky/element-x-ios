//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

final class NitroCatchUpServiceMock: NitroCatchUpServiceProtocol {
    let operationsSubject = CurrentValueSubject<[NitroCatchUpOperation], Never>([])
    let actionFailuresSubject = PassthroughSubject<String, Never>()
    var startResult: Result<Void, NitroCatchUpServiceError> = .success(())
    private(set) var startCalls = [(roomID: String, roomName: String, scope: NitroCatchUpScope, mode: NitroCatchUpMode)]()
    private(set) var restoreCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var cancelledOperationIDs = [String]()
    private(set) var dismissedOperationIDs = [String]()
    
    var operationsPublisher: CurrentValuePublisher<[NitroCatchUpOperation], Never> {
        operationsSubject.asCurrentValuePublisher()
    }
    
    var actionFailuresPublisher: AnyPublisher<String, Never> {
        actionFailuresSubject.eraseToAnyPublisher()
    }
    
    func start(roomID: String,
               roomName: String,
               scope: NitroCatchUpScope,
               mode: NitroCatchUpMode) -> Result<Void, NitroCatchUpServiceError> {
        startCalls.append((roomID, roomName, scope, mode))
        return startResult
    }
    
    func restore() {
        restoreCallCount += 1
    }
    
    func stop() {
        stopCallCount += 1
    }
    
    func cancel(operationID: String) {
        cancelledOperationIDs.append(operationID)
    }
    
    func dismiss(operationID: String) {
        dismissedOperationIDs.append(operationID)
    }
}
