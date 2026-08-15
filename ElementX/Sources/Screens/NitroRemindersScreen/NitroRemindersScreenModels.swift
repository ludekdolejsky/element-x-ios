//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NitroRemindersScreenViewModelAction {
    case openReminder(roomID: String, eventID: String, threadRootID: String?)
}

enum NitroRemindersScreenAlertID: Hashable {
    case invalidTime
    case requestFailed
}

struct NitroRemindersScreenViewState: BindableState {
    var reminders: [NitroReminder] = []
    var isLoading = false
    var hasLoaded = false
    var busyReminderID: String?
    var serverNow = Date()
    var bindings: NitroRemindersScreenViewStateBindings
}

struct NitroRemindersScreenViewStateBindings {
    var filter = NitroReminderFilter.due
    var editingReminder: NitroReminder?
    var editDate = Date()
    var alertInfo: AlertInfo<NitroRemindersScreenAlertID>?
}

enum NitroRemindersScreenViewAction {
    case load
    case refresh
    case selectFilter(NitroReminderFilter)
    case open(NitroReminder)
    case markDone(NitroReminder)
    case snooze(NitroReminder, TimeInterval)
    case edit(NitroReminder)
    case cancelEdit
    case saveEditedTime(reminderID: String)
    case delete(NitroReminder)
}
