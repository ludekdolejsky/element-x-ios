//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NitroReminderCreateScreenViewModelAction {
    case dismiss
}

enum NitroReminderCreatePreset: String, CaseIterable, Identifiable {
    case oneMinute
    case twentyMinutes
    case oneHour
    case tomorrowAtNine
    case twentyFourHours
    case mondayAtNine
    case oneWeek
    case custom
    
    var id: Self {
        self
    }
    
    var title: String {
        switch self {
        case .oneMinute: UntranslatedL10n.screenNitroReminderInOneMinuteIos
        case .twentyMinutes: UntranslatedL10n.screenNitroReminderIn20MinutesIos
        case .oneHour: UntranslatedL10n.screenNitroReminderInOneHourIos
        case .tomorrowAtNine: UntranslatedL10n.screenNitroReminderTomorrowNineIos
        case .twentyFourHours: UntranslatedL10n.screenNitroReminderIn24HoursIos
        case .mondayAtNine: UntranslatedL10n.screenNitroReminderMondayNineIos
        case .oneWeek: UntranslatedL10n.screenNitroReminderInOneWeekIos
        case .custom: UntranslatedL10n.screenNitroReminderCustomTimeIos
        }
    }
}

enum NitroReminderCreateAlertID: Hashable {
    case invalidTime
    case requestFailed
}

struct NitroReminderCreateScreenViewState: BindableState {
    var isSaving = false
    var bindings: NitroReminderCreateScreenViewStateBindings
}

struct NitroReminderCreateScreenViewStateBindings {
    var selectedPreset: NitroReminderCreatePreset = .twentyMinutes
    var customDate: Date
    var alertInfo: AlertInfo<NitroReminderCreateAlertID>?
}

enum NitroReminderCreateScreenViewAction {
    case cancel
    case setReminder
}
