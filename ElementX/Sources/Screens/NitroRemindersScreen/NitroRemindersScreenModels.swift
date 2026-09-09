//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NitroRemindersScreenViewModelAction {
    case openReminder(roomID: String, eventID: String?, threadRootID: String?)
}

enum NitroRemindersScreenAlertID: Hashable {
    case invalidTime
    case requestFailed
}

struct NitroRemindersScreenViewState: BindableState {
    var reminders: [NitroReminder] = []
    var previews = [String: NitroReminderMessagePreview]()
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

struct NitroReminderRowPresentation: Equatable {
    let badge: String?
    let prompt: String?
    let recurrence: String?
    let status: String
    let openAction: String
    
    init(reminder: NitroReminder, serverNow: Date) {
        if reminder.actionKind == .runCodex {
            badge = UntranslatedL10n.screenNitroRemindersRunsCodexIos
            let prompt = reminder.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.prompt = prompt?.isEmpty == false ? prompt : UntranslatedL10n.screenNitroRemindersCodexPromptUnavailableIos
            recurrence = Self.recurrenceDescription(reminder.recurrence)
        } else {
            badge = nil
            prompt = nil
            recurrence = nil
        }
        
        status = Self.statusDescription(reminder: reminder, serverNow: serverNow)
        openAction = reminder.messageEventID == nil
            ? UntranslatedL10n.actionOpenReminderRoomIos
            : UntranslatedL10n.actionOpenReminderMessageIos
    }
    
    private static func recurrenceDescription(_ recurrence: NitroReminderRecurrence?) -> String? {
        guard let recurrence else { return nil }
        let time = String(format: "%02d:%02d", recurrence.hour, recurrence.minute)
        switch recurrence.kind {
        case .daily:
            return UntranslatedL10n.screenNitroRemindersDailyRecurrenceIos(time, recurrence.timeZone)
        }
    }
    
    private static func statusDescription(reminder: NitroReminder, serverNow: Date) -> String {
        if let executionStatus = reminder.executionStatus {
            return switch executionStatus {
            case .scheduled: UntranslatedL10n.screenNitroRemindersExecutionScheduledIos
            case .claimed: UntranslatedL10n.screenNitroRemindersExecutionStartingIos
            case .waking: UntranslatedL10n.screenNitroRemindersExecutionWakingIos
            case .queued: UntranslatedL10n.screenNitroRemindersExecutionQueuedIos
            case .retrying: UntranslatedL10n.screenNitroRemindersExecutionRetryingIos
            case .submitting: UntranslatedL10n.screenNitroRemindersExecutionStartingIos
            case .done: UntranslatedL10n.screenNitroRemindersDoneIos
            case .deleted: UntranslatedL10n.screenNitroRemindersExecutionDeletedIos
            }
        }
        if reminder.status == .done {
            return UntranslatedL10n.screenNitroRemindersDoneIos
        }
        if reminder.dueDate <= serverNow {
            return UntranslatedL10n.screenNitroRemindersDueNowIos
        }
        return UntranslatedL10n.screenNitroRemindersUpcomingIos
    }
}
