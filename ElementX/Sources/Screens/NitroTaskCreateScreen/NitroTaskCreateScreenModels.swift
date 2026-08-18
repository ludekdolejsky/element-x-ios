//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NitroTaskCreateScreenViewModelAction {
    case dismiss(createdTask: NitroTask?)
}

enum NitroTaskCreateScreenAlertID: Hashable {
    case requestFailed
}

struct NitroTaskCreateScreenViewState: BindableState {
    let fixedRoomID: String?
    var rooms = [NitroTaskRoom]()
    var members = [NitroTaskMember]()
    var isLoading = false
    var isLoadingMembers = false
    var isSaving = false
    var hasLoaded = false
    var bindings: NitroTaskCreateScreenViewStateBindings
    
    var canSubmit: Bool {
        !bindings.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            bindings.selectedRoomID != nil &&
            !isLoading &&
            !isLoadingMembers &&
            !isSaving
    }
}

struct NitroTaskCreateScreenViewStateBindings {
    var title: String
    var description: String
    var selectedRoomID: String?
    var selectedAssigneeID: String?
    var alertInfo: AlertInfo<NitroTaskCreateScreenAlertID>?
}

enum NitroTaskCreateScreenViewAction {
    case load
    case selectRoom(String)
    case cancel
    case create
}
