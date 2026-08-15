//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

typealias NitroReminderCreateScreenViewModelType = StateStoreViewModelV2<NitroReminderCreateScreenViewState, NitroReminderCreateScreenViewAction>

final class NitroReminderCreateScreenViewModel: NitroReminderCreateScreenViewModelType, NitroReminderCreateScreenViewModelProtocol, Identifiable {
    private let eventID: String
    private let threadRootID: String?
    private let roomProxy: JoinedRoomProxyProtocol
    private let clientProxy: ClientProxyProtocol
    private let reminderService: NitroReminderServiceProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    private let calendar: Calendar
    private let now: () -> Date
    
    private var submitTask: Task<Void, Never>?
    
    private let actionsSubject = PassthroughSubject<NitroReminderCreateScreenViewModelAction, Never>()
    var actionsPublisher: AnyPublisher<NitroReminderCreateScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(eventID: String,
         threadRootID: String?,
         roomProxy: JoinedRoomProxyProtocol,
         clientProxy: ClientProxyProtocol,
         reminderService: NitroReminderServiceProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init) {
        self.eventID = eventID
        self.threadRootID = threadRootID
        self.roomProxy = roomProxy
        self.clientProxy = clientProxy
        self.reminderService = reminderService
        self.userIndicatorController = userIndicatorController
        self.calendar = calendar
        self.now = now
        
        super.init(initialViewState: .init(bindings: .init(customDate: now().addingTimeInterval(60 * 60))))
    }
    
    override func process(viewAction: NitroReminderCreateScreenViewAction) {
        switch viewAction {
        case .cancel:
            submitTask?.cancel()
            actionsSubject.send(.dismiss)
        case .setReminder:
            guard submitTask == nil else { return }
            submitTask = Task { [weak self] in
                await self?.submit()
            }
        }
    }
    
    private func submit() async {
        defer { submitTask = nil }
        
        let currentDate = now()
        let dueDate = dueDate(for: state.bindings.selectedPreset, relativeTo: currentDate)
        guard dueDate > currentDate else {
            state.bindings.alertInfo = .init(id: .invalidTime,
                                             title: UntranslatedL10n.errorReminderTimeInPastIos)
            return
        }
        
        state.isSaving = true
        defer { state.isSaving = false }
        
        guard case let .success(permalink) = await roomProxy.matrixToEventPermalink(eventID),
              !Task.isCancelled,
              let homeserverURL = URL(string: clientProxy.homeserver),
              case let .success(openIDToken) = await clientProxy.requestOpenIDToken(),
              !Task.isCancelled else {
            if !Task.isCancelled {
                showRequestFailure()
            }
            return
        }
        
        let target = NitroReminderTarget(roomID: roomProxy.id,
                                         roomName: roomProxy.infoPublisher.value.displayName ?? roomProxy.id,
                                         eventID: eventID,
                                         threadRootID: threadRootID,
                                         permalink: permalink)
        let schedule = NitroReminderSchedule(target: target,
                                             dueDate: dueDate,
                                             label: feedbackLabel(for: state.bindings.selectedPreset, dueDate: dueDate))
        
        switch await reminderService.createReminder(schedule,
                                                    authentication: .init(homeserverURL: homeserverURL, openIDToken: openIDToken)) {
        case .success:
            guard !Task.isCancelled else { return }
            userIndicatorController.submitIndicator(.init(type: .toast,
                                                          title: UntranslatedL10n.commonReminderSetIos,
                                                          icon: \.check))
            actionsSubject.send(.dismiss)
        case .failure(.cancelled):
            break
        case .failure:
            guard !Task.isCancelled else { return }
            showRequestFailure()
        }
    }
    
    private func dueDate(for preset: NitroReminderCreatePreset, relativeTo date: Date) -> Date {
        switch preset {
        case .oneMinute:
            date.addingTimeInterval(60)
        case .twentyMinutes:
            date.addingTimeInterval(20 * 60)
        case .oneHour:
            date.addingTimeInterval(60 * 60)
        case .tomorrowAtNine:
            calendar.date(bySettingHour: 9,
                          minute: 0,
                          second: 0,
                          of: calendar.date(byAdding: .day, value: 1, to: date) ?? date) ?? date
        case .twentyFourHours:
            date.addingTimeInterval(24 * 60 * 60)
        case .mondayAtNine:
            calendar.nextDate(after: date,
                              matching: DateComponents(hour: 9, weekday: 2),
                              matchingPolicy: .nextTime) ?? date
        case .oneWeek:
            date.addingTimeInterval(7 * 24 * 60 * 60)
        case .custom:
            state.bindings.customDate
        }
    }
    
    private func feedbackLabel(for preset: NitroReminderCreatePreset, dueDate: Date) -> String {
        switch preset {
        case .oneMinute: "in 1 minute"
        case .twentyMinutes: "in 20 minutes"
        case .oneHour: "in 1 hour"
        case .tomorrowAtNine: "tomorrow at 09:00"
        case .twentyFourHours: "in 24 hours"
        case .mondayAtNine: "on Monday at 09:00"
        case .oneWeek: "in 1 week"
        case .custom: "at \(dueDate.formatted(date: .abbreviated, time: .shortened))"
        }
    }
    
    private func showRequestFailure() {
        state.bindings.alertInfo = .init(id: .requestFailed,
                                         title: UntranslatedL10n.errorReminderRequestFailedIos)
    }
}
