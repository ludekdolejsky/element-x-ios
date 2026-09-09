//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroRemindersScreenViewModelTests {
    @Test
    func loadsDueReminders() async throws {
        let reminder = makeReminder()
        let reminderService = NitroReminderServiceMock()
        let previewService = NitroReminderPreviewServiceMock()
        let preview = NitroReminderMessagePreview(text: "Check the release",
                                                  sender: "Alice",
                                                  isEdited: true,
                                                  isAvailable: true)
        previewService.loadPreviewsForForceRefreshReturnValue = [.init(reminderID: reminder.id, preview: preview)]
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [reminder],
                                                                                  now: Date(timeIntervalSince1970: 1_700_000_100)))
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: reminderService,
                                                      previewService: previewService)
        let deferred = deferFulfillment(viewModel.context.observe(\.viewState.previews)) { $0[reminder.id] == preview }
        
        viewModel.context.send(viewAction: .load)
        try await deferred.fulfill()
        
        #expect(viewModel.context.viewState.reminders == [reminder])
        #expect(reminderService.remindersFilterAuthenticationReceivedArguments?.filter == .due)
        #expect(previewService.loadPreviewsForForceRefreshReceivedArguments?.reminders == [reminder])
        #expect(previewService.loadPreviewsForForceRefreshReceivedArguments?.forceRefresh == false)
    }
    
    @Test
    func loadsCodexReminderWithoutMessagePreview() async throws {
        let reminder = makeReminder(eventID: "",
                                    actionKind: .runCodex,
                                    prompt: "Summarise overnight activity",
                                    recurrence: .init(kind: .daily, hour: 9, minute: 5, timeZone: "Europe/Prague"),
                                    executionStatus: .queued)
        let reminderService = NitroReminderServiceMock()
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [reminder], now: .now))
        let previewService = NitroReminderPreviewServiceMock()
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: reminderService,
                                                      previewService: previewService)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        
        #expect(previewService.loadPreviewsForForceRefreshReceivedArguments == nil)
        let loadedReminder = try #require(viewModel.context.viewState.reminders.first)
        let presentation = NitroReminderRowPresentation(reminder: loadedReminder,
                                                        serverNow: viewModel.context.viewState.serverNow)
        #expect(presentation.badge == "Runs Codex")
        #expect(presentation.prompt == "Summarise overnight activity")
        #expect(presentation.recurrence == "Daily at 09:05 · Europe/Prague")
        #expect(presentation.status == "Queued")
        #expect(presentation.openAction == "Open room")
    }
    
    @Test
    func presentsCodexExecutionStatuses() {
        let statuses: [(NitroReminderExecutionStatus, String)] = [
            (.claimed, "Starting"),
            (.waking, "Waking"),
            (.queued, "Queued"),
            (.retrying, "Retrying")
        ]
        
        for (status, expected) in statuses {
            let reminder = makeReminder(actionKind: .runCodex, executionStatus: status)
            #expect(NitroReminderRowPresentation(reminder: reminder, serverNow: .now).status == expected)
        }
    }
    
    @Test
    func preservesOtherMessagePreviewsAfterMutation() async throws {
        let firstReminder = makeReminder(id: "reminder-1", eventID: "$event-1:example.org")
        let secondReminder = makeReminder(id: "reminder-2", eventID: "$event-2:example.org")
        let reminderService = NitroReminderServiceMock()
        let previewService = NitroReminderPreviewServiceMock()
        let secondPreview = NitroReminderMessagePreview(text: "Keep this preview",
                                                        sender: "Alice",
                                                        isEdited: false,
                                                        isAvailable: true)
        previewService.loadPreviewsForForceRefreshReturnValue = [
            .init(reminderID: firstReminder.id,
                  preview: .init(text: "Complete this", sender: "Bob", isEdited: false, isAvailable: true)),
            .init(reminderID: secondReminder.id, preview: secondPreview)
        ]
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [firstReminder, secondReminder], now: .now))
        reminderService.markDoneReminderIDAuthenticationReturnValue = .success(firstReminder)
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: reminderService,
                                                      previewService: previewService)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.previews)) { $0[secondReminder.id] == secondPreview }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        
        previewService.loadPreviewsForForceRefreshReturnValue = []
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [secondReminder], now: .now))
        let mutationFinished = deferFulfillment(viewModel.context.observe(\.viewState.reminders)) { $0 == [secondReminder] }
        viewModel.context.send(viewAction: .markDone(firstReminder))
        try await mutationFinished.fulfill()
        
        #expect(viewModel.context.viewState.previews[secondReminder.id] == secondPreview)
        #expect(previewService.loadPreviewsForForceRefreshReceivedArguments?.forceRefresh == false)
    }
    
    @Test
    func stopCancelsPreviewLoadingAndIgnoresLaterUpdates() async {
        let reminder = makeReminder()
        let reminderService = NitroReminderServiceMock()
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [reminder], now: .now))
        let previewService = NitroReminderPreviewServiceMock()
        let (updates, updatesContinuation) = AsyncStream.makeStream(of: NitroReminderPreviewUpdate.self)
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        previewService.loadPreviewsForForceRefreshClosure = { _, _, update in
            startedContinuation.yield()
            startedContinuation.finish()
            for await value in updates {
                guard !Task.isCancelled else { return }
                update(value)
            }
        }
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: reminderService,
                                                      previewService: previewService)
        
        viewModel.context.send(viewAction: .load)
        for await _ in started {
            break
        }
        viewModel.stop()
        updatesContinuation.yield(.init(reminderID: reminder.id,
                                        preview: .init(text: "Late update", sender: nil, isEdited: false, isAvailable: true)))
        updatesContinuation.finish()
        await Task.yield()
        
        #expect(viewModel.context.viewState.previews[reminder.id] == nil)
    }
    
    @Test
    func opensThreadReminder() async throws {
        let reminder = makeReminder(threadRootID: "$root:example.org")
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: NitroReminderServiceMock(),
                                                      previewService: NitroReminderPreviewServiceMock())
        let deferred = deferFulfillment(viewModel.actionsPublisher) { action in
            guard case let .openReminder(roomID, eventID, threadRootID) = action else { return false }
            return roomID == reminder.roomID && eventID == reminder.messageEventID && threadRootID == reminder.threadRootID
        }
        
        viewModel.context.send(viewAction: .open(reminder))
        try await deferred.fulfill()
    }
    
    @Test
    func opensRoomWhenReminderHasNoMessageEvent() async throws {
        let reminder = makeReminder(eventID: "", actionKind: .runCodex)
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: NitroReminderServiceMock(),
                                                      previewService: NitroReminderPreviewServiceMock())
        let deferred = deferFulfillment(viewModel.actionsPublisher) { action in
            guard case let .openReminder(roomID, eventID, threadRootID) = action else { return false }
            return roomID == reminder.roomID && eventID == nil && threadRootID == nil
        }
        
        viewModel.context.send(viewAction: .open(reminder))
        try await deferred.fulfill()
    }
    
    @Test
    func snoozesReminderForTwentyMinutes() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = makeReminder(actionKind: .runCodex)
        let reminderService = NitroReminderServiceMock()
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [reminder], now: now))
        reminderService.snoozeReminderIDUntilAuthenticationReturnValue = .success(reminder)
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: reminderService,
                                                      previewService: NitroReminderPreviewServiceMock()) { now }
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [], now: now))
        let removed = deferFulfillment(viewModel.context.observe(\.viewState.reminders)) { $0.isEmpty }
        viewModel.context.send(viewAction: .snooze(reminder, 20 * 60))
        try await removed.fulfill()
        
        let arguments = try #require(reminderService.snoozeReminderIDUntilAuthenticationReceivedArguments)
        #expect(arguments.reminderID == reminder.id)
        #expect(arguments.dueDate == now.addingTimeInterval(20 * 60))
    }
    
    @Test
    func marksCodexReminderDone() async throws {
        let reminder = makeReminder(actionKind: .runCodex)
        let reminderService = NitroReminderServiceMock()
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [reminder], now: .now))
        reminderService.markDoneReminderIDAuthenticationReturnValue = .success(reminder)
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: reminderService,
                                                      previewService: NitroReminderPreviewServiceMock())
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [], now: .now))
        let removed = deferFulfillment(viewModel.context.observe(\.viewState.reminders)) { $0.isEmpty }
        viewModel.context.send(viewAction: .markDone(reminder))
        try await removed.fulfill()
        
        #expect(reminderService.markDoneReminderIDAuthenticationReceivedArguments?.reminderID == reminder.id)
    }
    
    @Test
    func deletesCodexReminder() async throws {
        let reminder = makeReminder(actionKind: .runCodex)
        let reminderService = NitroReminderServiceMock()
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [reminder], now: .now))
        reminderService.deleteReminderReminderIDAuthenticationReturnValue = .success(())
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: reminderService,
                                                      previewService: NitroReminderPreviewServiceMock())
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [], now: .now))
        let removed = deferFulfillment(viewModel.context.observe(\.viewState.reminders)) { $0.isEmpty }
        viewModel.context.send(viewAction: .delete(reminder))
        try await removed.fulfill()
        
        #expect(reminderService.deleteReminderReminderIDAuthenticationReceivedArguments?.reminderID == reminder.id)
    }
    
    @Test
    func cancelDoesNotDismissEditWhileSaving() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = makeReminder(actionKind: .runCodex)
        let reminderService = NitroReminderServiceMock()
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [], now: now))
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        reminderService.snoozeReminderIDUntilAuthenticationClosure = { _, _, _ in
            for await _ in stream {
                break
            }
            return .success(reminder)
        }
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: reminderService,
                                                      previewService: NitroReminderPreviewServiceMock()) { now }
        viewModel.context.send(viewAction: .edit(reminder))
        let finished = deferFulfillment(viewModel.context.observe(\.viewState.bindings.editingReminder)) { $0 == nil }
        
        viewModel.context.send(viewAction: .saveEditedTime(reminderID: reminder.id))
        #expect(viewModel.context.viewState.busyReminderID == reminder.id)
        viewModel.context.send(viewAction: .cancelEdit)
        #expect(viewModel.context.viewState.bindings.editingReminder == reminder)
        continuation.yield()
        continuation.finish()
        try await finished.fulfill()
    }
    
    private func makeClientProxy() -> NitroClientProxyMock {
        let clientProxy = NitroClientProxyMock(homeserver: "https://matrix.example.org")
        clientProxy.requestOpenIDTokenReturnValue = .success(.init(accessToken: "secret-token",
                                                                   tokenType: "Bearer",
                                                                   matrixServerName: "example.org"))
        return clientProxy
    }
    
    private func makeReminder(id: String = "reminder-1",
                              eventID: String = "$event:example.org",
                              threadRootID: String? = nil,
                              actionKind: NitroReminderActionKind = .notify,
                              prompt: String? = nil,
                              recurrence: NitroReminderRecurrence? = nil,
                              executionStatus: NitroReminderExecutionStatus? = nil) -> NitroReminder {
        .init(id: id,
              userID: "@alice:example.org",
              homeserverURL: "https://matrix.example.org",
              roomID: "!room:example.org",
              roomName: "Nitro team",
              eventID: eventID,
              threadRootID: threadRootID,
              dueTimestamp: 1_700_000_200,
              label: "in 20 minutes",
              permalink: "https://matrix.to/#/!room:example.org/$event:example.org",
              createdTimestamp: 1_700_000_000,
              deliveredTimestamp: nil,
              updatedTimestamp: 1_700_000_000,
              status: .pending,
              error: nil,
              actionKind: actionKind,
              prompt: prompt,
              recurrence: recurrence,
              executionStatus: executionStatus)
    }
}
