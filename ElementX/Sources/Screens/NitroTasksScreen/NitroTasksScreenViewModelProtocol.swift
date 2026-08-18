//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine

protocol NitroTasksScreenViewModelProtocol {
    var actionsPublisher: AnyPublisher<NitroTasksScreenViewModelAction, Never> { get }
    var context: NitroTasksScreenViewModel.Context { get }
    func refresh()
    func show(room: NitroTaskRoom)
}
