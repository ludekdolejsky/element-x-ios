//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NitroCatchUpScreenViewModelAction {
    case dismiss
}

enum NitroCatchUpStartPoint: String, CaseIterable, Identifiable {
    case lastRead
    case date
    
    var id: Self {
        self
    }
}

enum NitroCatchUpScreenAlertID: Hashable {
    case requestFailed
}

struct NitroCatchUpScreenViewState: BindableState {
    let roomName: String
    var operation: NitroCatchUpOperation?
    var bindings: NitroCatchUpScreenViewStateBindings
}

struct NitroCatchUpScreenViewStateBindings {
    var startPoint = NitroCatchUpStartPoint.lastRead
    var date = Date().addingTimeInterval(-24 * 60 * 60)
    var mode = NitroCatchUpMode.overview
    var alertInfo: AlertInfo<NitroCatchUpScreenAlertID>?
}

enum NitroCatchUpScreenViewAction {
    case close
    case start
    case cancel
    case dismissResult
}
