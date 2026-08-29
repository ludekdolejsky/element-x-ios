//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

protocol NitroRoomWidgetsScreenViewModelProtocol {
    var actions: AnyPublisher<NitroRoomWidgetsScreenViewModelAction, Never> { get }
    var context: NitroRoomWidgetsScreenViewModel.Context { get }
    
    func stop()
}
