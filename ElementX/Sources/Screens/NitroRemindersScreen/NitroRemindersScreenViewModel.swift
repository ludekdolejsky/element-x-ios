//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

typealias NitroRemindersScreenViewModelType = StateStoreViewModelV2<NitroRemindersScreenViewState, NitroRemindersScreenViewAction>

final class NitroRemindersScreenViewModel: NitroRemindersScreenViewModelType, NitroRemindersScreenViewModelProtocol {
    private enum Mutation {
        case markDone
        case snooze(Date)
        case delete
    }
    
    private let clientProxy: NitroClientProxyProtocol
    private let reminderService: NitroReminderServiceProtocol
    private let previewService: NitroReminderPreviewServiceProtocol
    private let now: () -> Date
    
    private var loadTask: Task<Void, Never>?
    private var loadTaskID: UUID?
    private var previewTask: Task<Void, Never>?
    private var previewTaskID: UUID?
    private var mutationTask: Task<Void, Never>?
    private var mutationTaskID: UUID?
    
    private let actionsSubject = PassthroughSubject<NitroRemindersScreenViewModelAction, Never>()
    var actionsPublisher: AnyPublisher<NitroRemindersScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(clientProxy: NitroClientProxyProtocol,
         reminderService: NitroReminderServiceProtocol,
         previewService: NitroReminderPreviewServiceProtocol,
         now: @escaping () -> Date = Date.init) {
        self.clientProxy = clientProxy
        self.reminderService = reminderService
        self.previewService = previewService
        self.now = now
        super.init(initialViewState: .init(bindings: .init()))
    }
    
    isolated deinit {
        loadTask?.cancel()
        previewTask?.cancel()
        mutationTask?.cancel()
    }
    
    override func process(viewAction: NitroRemindersScreenViewAction) {
        switch viewAction {
        case .load:
            startLoad(forcePreviewRefresh: false)
        case .refresh:
            startLoad(forcePreviewRefresh: true)
        case .selectFilter(let filter):
            state.bindings.filter = filter
            state.reminders = []
            state.hasLoaded = false
            startLoad(forcePreviewRefresh: false)
        case .open(let reminder):
            actionsSubject.send(.openReminder(roomID: reminder.roomID,
                                              eventID: reminder.eventID,
                                              threadRootID: reminder.threadRootID))
        case .markDone(let reminder):
            startMutation(.markDone, reminderID: reminder.id)
        case .snooze(let reminder, let delay):
            startMutation(.snooze(now().addingTimeInterval(delay)), reminderID: reminder.id)
        case .edit(let reminder):
            state.bindings.editDate = max(reminder.dueDate, now().addingTimeInterval(60))
            state.bindings.editingReminder = reminder
        case .cancelEdit:
            guard state.busyReminderID == nil else { return }
            state.bindings.editingReminder = nil
        case .saveEditedTime(let reminderID):
            guard state.bindings.editDate > now() else {
                state.bindings.alertInfo = .init(id: .invalidTime,
                                                 title: UntranslatedL10n.errorReminderTimeInPastIos)
                return
            }
            startMutation(.snooze(state.bindings.editDate), reminderID: reminderID)
        case .delete(let reminder):
            startMutation(.delete, reminderID: reminder.id)
        }
    }
    
    func refresh() {
        startLoad(forcePreviewRefresh: false)
    }
    
    func stop() {
        loadTask?.cancel()
        loadTask = nil
        loadTaskID = nil
        previewTask?.cancel()
        previewTask = nil
        previewTaskID = nil
        mutationTask?.cancel()
        mutationTask = nil
        mutationTaskID = nil
        state.isLoading = false
        state.busyReminderID = nil
    }
    
    private func startLoad(forcePreviewRefresh: Bool) {
        loadTask?.cancel()
        let taskID = UUID()
        loadTaskID = taskID
        let filter = state.bindings.filter
        loadTask = Task { [weak self] in
            await self?.load(filter: filter, forcePreviewRefresh: forcePreviewRefresh, taskID: taskID)
        }
    }
    
    private func load(filter: NitroReminderFilter, forcePreviewRefresh: Bool, taskID: UUID) async {
        state.isLoading = true
        defer {
            if loadTaskID == taskID {
                state.isLoading = false
                loadTask = nil
                loadTaskID = nil
            }
        }
        
        guard case let .success(authentication) = await authentication(),
              !Task.isCancelled else {
            if !Task.isCancelled, loadTaskID == taskID {
                showRequestFailure()
                state.hasLoaded = true
            }
            return
        }
        
        switch await reminderService.reminders(filter: filter, authentication: authentication) {
        case .success(let result):
            guard !Task.isCancelled,
                  loadTaskID == taskID,
                  state.bindings.filter == filter else { return }
            state.reminders = result.reminders
            state.previews = state.previews.filter { preview in
                result.reminders.contains { $0.id == preview.key }
            }
            state.serverNow = result.now
            state.hasLoaded = true
            startPreviewLoad(for: result.reminders, forceRefresh: forcePreviewRefresh)
        case .failure(.cancelled):
            break
        case .failure:
            guard !Task.isCancelled, loadTaskID == taskID else { return }
            showRequestFailure()
            state.hasLoaded = true
        }
    }
    
    private func startPreviewLoad(for reminders: [NitroReminder], forceRefresh: Bool) {
        previewTask?.cancel()
        let taskID = UUID()
        previewTaskID = taskID
        if forceRefresh {
            for reminder in reminders {
                state.previews[reminder.id] = nil
            }
        }
        let previewService = previewService
        previewTask = Task { [weak self, previewService] in
            await previewService.loadPreviews(for: reminders, forceRefresh: forceRefresh) { [weak self] update in
                guard let self else { return }
                guard !Task.isCancelled, previewTaskID == taskID else { return }
                state.previews[update.reminderID] = update.preview
            }
            guard let self else { return }
            guard !Task.isCancelled, previewTaskID == taskID else { return }
            previewTask = nil
            previewTaskID = nil
        }
    }
    
    private func startMutation(_ mutation: Mutation, reminderID: String) {
        guard mutationTask == nil else { return }
        let taskID = UUID()
        mutationTaskID = taskID
        state.busyReminderID = reminderID
        mutationTask = Task { [weak self] in
            await self?.runMutation(mutation, reminderID: reminderID, taskID: taskID)
        }
    }
    
    private func runMutation(_ mutation: Mutation, reminderID: String, taskID: UUID) async {
        defer {
            if mutationTaskID == taskID {
                mutationTask = nil
                mutationTaskID = nil
                state.busyReminderID = nil
            }
        }
        
        guard case let .success(authentication) = await authentication(),
              !Task.isCancelled else {
            if !Task.isCancelled {
                showRequestFailure()
            }
            return
        }
        
        let result: Result<Void, NitroReminderError>
        switch mutation {
        case .markDone:
            result = await reminderService.markDone(reminderID: reminderID, authentication: authentication).map { _ in () }
        case .snooze(let dueDate):
            result = await reminderService.snooze(reminderID: reminderID,
                                                  until: dueDate,
                                                  authentication: authentication).map { _ in () }
        case .delete:
            result = await reminderService.deleteReminder(reminderID: reminderID, authentication: authentication)
        }
        
        guard !Task.isCancelled else { return }
        switch result {
        case .success:
            state.bindings.editingReminder = nil
            state.reminders.removeAll { $0.id == reminderID }
            startLoadAfterMutation(taskID: taskID)
        case .failure(.cancelled):
            break
        case .failure:
            showRequestFailure()
        }
    }
    
    private func startLoadAfterMutation(taskID: UUID) {
        guard mutationTaskID == taskID else { return }
        mutationTask = nil
        mutationTaskID = nil
        state.busyReminderID = nil
        startLoad(forcePreviewRefresh: false)
    }
    
    private func authentication() async -> Result<NitroReminderAuthentication, NitroReminderError> {
        guard !Task.isCancelled,
              let homeserverURL = URL(string: clientProxy.homeserver),
              case let .success(openIDToken) = await clientProxy.requestOpenIDToken(),
              !Task.isCancelled else {
            return Task.isCancelled ? .failure(.cancelled) : .failure(.invalidResponse)
        }
        return .success(.init(homeserverURL: homeserverURL, openIDToken: openIDToken))
    }
    
    private func showRequestFailure() {
        state.bindings.alertInfo = .init(id: .requestFailed,
                                         title: UntranslatedL10n.errorReminderRequestFailedIos)
    }
}
