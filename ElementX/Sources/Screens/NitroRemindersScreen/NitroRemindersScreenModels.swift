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

struct NitroReminderRoom: Equatable, Identifiable {
    let id: String
    let name: String
}

enum NitroRemindersScreenAlertID: Hashable {
    case invalidTime
    case requestFailed
}

struct NitroRemindersScreenViewState: BindableState {
    var reminders: [NitroReminder] = []
    var knownRooms: [NitroReminderRoom] = []
    var previews = [String: NitroReminderMessagePreview]()
    var isLoading = false
    var hasLoaded = false
    var busyReminderID: String?
    var serverNow = Date()
    var filterRoomContext: NitroReminderRoom?
    var bindings: NitroRemindersScreenViewStateBindings

    var rooms: [NitroReminderRoom] {
        var roomsByID = [String: NitroReminderRoom]()
        for room in knownRooms {
            roomsByID[room.id] = room
        }
        for reminder in reminders {
            roomsByID[reminder.roomID] = .init(id: reminder.roomID,
                                               name: reminder.roomName ?? reminder.roomID)
        }
        if let filterRoomContext {
            roomsByID[filterRoomContext.id] = filterRoomContext
        }
        return roomsByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var filteredReminders: [NitroReminder] {
        guard let selectedRoomID = bindings.selectedRoomID else { return reminders }
        return reminders.filter { $0.roomID == selectedRoomID }
    }
}

struct NitroRemindersScreenViewStateBindings {
    var filter = NitroReminderFilter.due
    var selectedRoomID: String?
    var editingReminder: NitroReminder?
    var editDate = Date()
    var alertInfo: AlertInfo<NitroRemindersScreenAlertID>?
}

enum NitroRemindersScreenViewAction {
    case load
    case refresh
    case selectFilter(NitroReminderFilter)
    case selectRoom(String?)
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
    let metadata: String
    let status: String
    let openAction: String
    
    init(reminder: NitroReminder, serverNow: Date) {
        if reminder.actionKind == .runCodex {
            badge = UntranslatedL10n.screenNitroRemindersRunsCodexIos
            let prompt = reminder.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.prompt = prompt?.isEmpty == false ? prompt : UntranslatedL10n.screenNitroRemindersCodexPromptUnavailableIos
            metadata = Self.codexMetadata(reminder)
        } else {
            badge = nil
            prompt = nil
            metadata = UntranslatedL10n.screenNitroRemindersMetaIos(Self.formatted(reminder.createdDate), Self.formatted(reminder.dueDate))
        }
        
        status = Self.statusDescription(reminder: reminder, serverNow: serverNow)
        openAction = reminder.messageEventID == nil
            ? UntranslatedL10n.actionOpenReminderRoomIos
            : UntranslatedL10n.actionOpenReminderMessageIos
    }

    private static func codexMetadata(_ reminder: NitroReminder) -> String {
        var parts = [String]()
        if let recurrence = recurrenceDescription(reminder.recurrence) {
            parts.append(recurrence)
        }
        if let lastFiredDate = reminder.lastFiredDate {
            parts.append(UntranslatedL10n.screenNitroRemindersLastRunIos(formatted(lastFiredDate)))
        }
        if reminder.status == .pending {
            parts.append(UntranslatedL10n.screenNitroRemindersNextRunIos(formatted(reminder.dueDate)))
        } else if parts.isEmpty {
            parts.append(UntranslatedL10n.screenNitroRemindersMetaIos(formatted(reminder.createdDate), formatted(reminder.dueDate)))
        }
        return parts.joined(separator: " · ")
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

    private static func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
