//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

protocol NitroTaskCreateScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<NitroTaskCreateScreenViewModelAction, Never> { get }
    var context: NitroTaskCreateScreenViewModel.Context { get }
}
