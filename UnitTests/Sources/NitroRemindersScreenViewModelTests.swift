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
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [reminder],
                                                                                  now: Date(timeIntervalSince1970: 1_700_000_100)))
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: reminderService)
        let deferred = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        
        viewModel.context.send(viewAction: .load)
        try await deferred.fulfill()
        
        #expect(viewModel.context.viewState.reminders == [reminder])
        #expect(reminderService.remindersFilterAuthenticationReceivedArguments?.filter == .due)
    }
    
    @Test
    func opensThreadReminder() async throws {
        let reminder = makeReminder(threadRootID: "$root:example.org")
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: NitroReminderServiceMock())
        let deferred = deferFulfillment(viewModel.actionsPublisher) { action in
            guard case let .openReminder(roomID, eventID, threadRootID) = action else { return false }
            return roomID == reminder.roomID && eventID == reminder.eventID && threadRootID == reminder.threadRootID
        }
        
        viewModel.context.send(viewAction: .open(reminder))
        try await deferred.fulfill()
    }
    
    @Test
    func snoozesReminderForTwentyMinutes() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = makeReminder()
        let reminderService = NitroReminderServiceMock()
        reminderService.remindersFilterAuthenticationReturnValue = .success(.init(reminders: [reminder], now: now))
        reminderService.snoozeReminderIDUntilAuthenticationReturnValue = .success(reminder)
        let viewModel = NitroRemindersScreenViewModel(clientProxy: makeClientProxy(),
                                                      reminderService: reminderService) { now }
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
    func cancelDoesNotDismissEditWhileSaving() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = makeReminder()
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
                                                      reminderService: reminderService) { now }
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
    
    private func makeClientProxy() -> ClientProxyMock {
        let clientProxy = ClientProxyMock(.init(homeserver: "https://matrix.example.org"))
        clientProxy.requestOpenIDTokenReturnValue = .success(.init(accessToken: "secret-token",
                                                                   tokenType: "Bearer",
                                                                   matrixServerName: "example.org"))
        return clientProxy
    }
    
    private func makeReminder(threadRootID: String? = nil) -> NitroReminder {
        .init(id: "reminder-1",
              userID: "@alice:example.org",
              homeserverURL: "https://matrix.example.org",
              roomID: "!room:example.org",
              roomName: "Nitro team",
              eventID: "$event:example.org",
              threadRootID: threadRootID,
              dueTimestamp: 1_700_000_200,
              label: "in 20 minutes",
              permalink: "https://matrix.to/#/!room:example.org/$event:example.org",
              createdTimestamp: 1_700_000_000,
              deliveredTimestamp: nil,
              updatedTimestamp: 1_700_000_000,
              status: .pending,
              error: nil)
    }
}
