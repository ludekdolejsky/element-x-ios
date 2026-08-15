//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroReminderCreateScreenViewModelTests {
    @Test
    func createsDefaultTwentyMinuteReminder() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let roomProxy = JoinedRoomProxyMock(.init(id: "!room:example.org", name: "Nitro team"))
        roomProxy.matrixToEventPermalinkReturnValue = .success("https://matrix.to/#/!room:example.org/$event:example.org")
        let clientProxy = ClientProxyMock(.init(homeserver: "https://matrix.example.org"))
        clientProxy.requestOpenIDTokenReturnValue = .success(.init(accessToken: "secret-token",
                                                                   tokenType: "Bearer",
                                                                   matrixServerName: "example.org"))
        let reminderService = NitroReminderServiceMock()
        reminderService.createReminderAuthenticationReturnValue = .success(.init(id: "reminder-1",
                                                                                 dueDate: now.addingTimeInterval(20 * 60)))
        let viewModel = NitroReminderCreateScreenViewModel(eventID: "$event:example.org",
                                                           threadRootID: "$root:example.org",
                                                           roomProxy: roomProxy,
                                                           clientProxy: clientProxy,
                                                           reminderService: reminderService,
                                                           userIndicatorController: UserIndicatorControllerMock()) { now }
        let deferred = deferFulfillment(viewModel.actionsPublisher) { action in
            if case .dismiss = action {
                true
            } else {
                false
            }
        }
        
        viewModel.context.send(viewAction: .setReminder)
        try await deferred.fulfill()
        
        let schedule = try #require(reminderService.createReminderAuthenticationReceivedArguments?.schedule)
        #expect(schedule.target.roomID == "!room:example.org")
        #expect(schedule.target.roomName == "Nitro team")
        #expect(schedule.target.eventID == "$event:example.org")
        #expect(schedule.target.threadRootID == "$root:example.org")
        #expect(schedule.dueDate == now.addingTimeInterval(20 * 60))
        #expect(schedule.label == "in 20 minutes")
    }
    
    @Test
    func rejectsPastCustomDate() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clientProxy = ClientProxyMock(.init(homeserver: "https://matrix.example.org"))
        let reminderService = NitroReminderServiceMock()
        let viewModel = NitroReminderCreateScreenViewModel(eventID: "$event:example.org",
                                                           threadRootID: nil,
                                                           roomProxy: JoinedRoomProxyMock(.init()),
                                                           clientProxy: clientProxy,
                                                           reminderService: reminderService,
                                                           userIndicatorController: UserIndicatorControllerMock()) { now }
        viewModel.context.selectedPreset = .custom
        viewModel.context.customDate = now.addingTimeInterval(-1)
        let deferred = deferFulfillment(viewModel.context.observe(\.viewState.bindings.alertInfo)) { $0?.id == .invalidTime }
        
        viewModel.context.send(viewAction: .setReminder)
        try await deferred.fulfill()
        
        #expect(viewModel.context.alertInfo?.id == .invalidTime)
        #expect(!reminderService.createReminderAuthenticationCalled)
    }
}
