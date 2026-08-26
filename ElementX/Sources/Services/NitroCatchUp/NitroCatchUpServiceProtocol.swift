//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

protocol NitroCatchUpServiceProtocol: AnyObject {
    var operationsPublisher: CurrentValuePublisher<[NitroCatchUpOperation], Never> { get }
    var actionFailuresPublisher: AnyPublisher<String, Never> { get }
    
    func start(roomID: String, roomName: String, scope: NitroCatchUpScope, mode: NitroCatchUpMode) -> Result<Void, NitroCatchUpServiceError>
    func restore()
    func stop()
    func cancel(operationID: String)
    func dismiss(operationID: String)
}
