//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import Testing

struct NitroReminderPreviewServiceTests {
    @Test
    func subscribesToFocusedTimelineBeforePublishingPreview() async {
        let reminder = makeReminder()
        let provider = makeProvider(eventID: reminder.eventID, body: "Reminder source")
        let timeline = TimelineProxyMock()
        timeline.subscribeForUpdatesFetchMembersClosure = { fetchMembers in
            #expect(!fetchMembers)
            timeline.timelineItemProvider = provider
        }
        let room = JoinedRoomProxyMock(.init(id: reminder.roomID))
        room.timelineFocusedOnEventEventIDNumberOfEventsReturnValue = .success(timeline)
        let client = ClientProxyMock(.init())
        client.roomForIdentifierClosure = { _ in .joined(room) }
        let service = NitroReminderPreviewService(clientProxy: client)
        
        let updates = await collect(from: service, reminder: reminder)
        
        #expect(timeline.subscribeForUpdatesFetchMembersCalled)
        #expect(timeline.subscribeForUpdatesFetchMembersReceivedFetchMembers == false)
        #expect(updates == [.init(reminderID: reminder.id,
                                  preview: .init(text: "Reminder source", sender: "Alice", isEdited: false, isAvailable: true))])
    }
    
    @Test
    func retriesUnavailablePreviewAfterNegativeCacheExpires() async {
        let reminder = makeReminder()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let room = JoinedRoomProxyMock(.init(id: reminder.roomID))
        room.timelineFocusedOnEventEventIDNumberOfEventsReturnValue = .failure(.eventNotFound)
        let client = ClientProxyMock(.init())
        client.roomForIdentifierClosure = { _ in .joined(room) }
        let service = NitroReminderPreviewService(clientProxy: client) { now }
        
        let firstUpdates = await collect(from: service, reminder: reminder)
        room.timelineFocusedOnEventEventIDNumberOfEventsReturnValue = .success(makeTimeline(eventID: reminder.eventID, body: "Now available"))
        let cachedUpdates = await collect(from: service, reminder: reminder)
        now.addTimeInterval(61)
        let retriedUpdates = await collect(from: service, reminder: reminder)
        
        #expect(firstUpdates.first?.preview.isAvailable == false)
        #expect(cachedUpdates.first?.preview.isAvailable == false)
        #expect(retriedUpdates.first?.preview.text == "Now available")
        #expect(room.timelineFocusedOnEventEventIDNumberOfEventsCallsCount == 2)
    }
    
    @Test
    func refreshesAvailablePreviewAfterCacheExpires() async {
        let reminder = makeReminder()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let room = JoinedRoomProxyMock(.init(id: reminder.roomID))
        room.timelineFocusedOnEventEventIDNumberOfEventsReturnValue = .success(makeTimeline(eventID: reminder.eventID, body: "Original"))
        let client = ClientProxyMock(.init())
        client.roomForIdentifierClosure = { _ in .joined(room) }
        let service = NitroReminderPreviewService(clientProxy: client) { now }
        
        let firstUpdates = await collect(from: service, reminder: reminder)
        room.timelineFocusedOnEventEventIDNumberOfEventsReturnValue = .success(makeTimeline(eventID: reminder.eventID, body: "Edited"))
        let cachedUpdates = await collect(from: service, reminder: reminder)
        now.addTimeInterval(301)
        let refreshedUpdates = await collect(from: service, reminder: reminder)
        
        #expect(firstUpdates.first?.preview.text == "Original")
        #expect(cachedUpdates.first?.preview.text == "Original")
        #expect(refreshedUpdates.first?.preview.text == "Edited")
        #expect(room.timelineFocusedOnEventEventIDNumberOfEventsCallsCount == 2)
    }
    
    @Test
    func extractsEditedMessagePreview() throws {
        let eventID = "$event:example.org"
        let body = "Updated reminder source"
        let messageType = MessageType.text(content: .init(body: body, formatted: nil))
        let content = TimelineItemContent.msgLike(content: .init(kind: .message(content: .init(msgType: messageType,
                                                                                               body: body,
                                                                                               isEdited: true,
                                                                                               mentions: nil)),
                                                                 reactions: [],
                                                                 inReplyTo: nil,
                                                                 threadRoot: nil,
                                                                 threadSummary: nil))
        let item = EventTimelineItem(configuration: .init(eventID: eventID,
                                                          sender: "@alice:example.org",
                                                          senderProfile: .ready(displayName: "Alice",
                                                                                displayNameAmbiguous: false,
                                                                                avatarUrl: nil,
                                                                                status: nil,
                                                                                call: nil),
                                                          content: content))
        let proxy = TimelineItemProxy.event(.init(item: item, uniqueID: .init("preview")))
        let preview = try #require(NitroReminderPreviewService.preview(for: eventID, in: [proxy]))
        
        #expect(preview.text == body)
        #expect(preview.sender == "Alice")
        #expect(preview.isEdited)
        #expect(preview.isAvailable)
    }
    
    @Test
    func ignoresUnrelatedEvents() {
        let proxy = TimelineItemProxy.mockOwnMessage("Different event")
        
        #expect(NitroReminderPreviewService.preview(for: "$missing:example.org", in: [proxy]) == nil)
    }
    
    @Test
    func skipsCodexRemindersWithoutLoadingMatrixEvents() async {
        let client = ClientProxyMock(.init())
        let service = NitroReminderPreviewService(clientProxy: client)
        let reminder = makeReminder(eventID: "", actionKind: .runCodex)
        
        let updates = await collect(from: service, reminder: reminder)
        
        #expect(updates.isEmpty)
        #expect(!client.roomForIdentifierCalled)
    }
    
    private func collect(from service: NitroReminderPreviewService, reminder: NitroReminder) async -> [NitroReminderPreviewUpdate] {
        var updates = [NitroReminderPreviewUpdate]()
        await service.loadPreviews(for: [reminder], forceRefresh: false) { update in
            updates.append(update)
        }
        return updates
    }
    
    private func makeTimeline(eventID: String, body: String) -> TimelineProxyMock {
        TimelineProxyMock(.init(timelineItemProvider: makeProvider(eventID: eventID, body: body)))
    }
    
    private func makeProvider(eventID: String, body: String) -> TimelineItemProviderMock {
        let messageType = MessageType.text(content: .init(body: body, formatted: nil))
        let content = TimelineItemContent.msgLike(content: .init(kind: .message(content: .init(msgType: messageType,
                                                                                               body: body,
                                                                                               isEdited: false,
                                                                                               mentions: nil)),
                                                                 reactions: [],
                                                                 inReplyTo: nil,
                                                                 threadRoot: nil,
                                                                 threadSummary: nil))
        let item = EventTimelineItem(configuration: .init(eventID: eventID,
                                                          sender: "@alice:example.org",
                                                          senderProfile: .ready(displayName: "Alice",
                                                                                displayNameAmbiguous: false,
                                                                                avatarUrl: nil,
                                                                                status: nil,
                                                                                call: nil),
                                                          content: content))
        let provider = TimelineItemProviderMock()
        provider.itemProxies = [.event(.init(item: item, uniqueID: .init("preview-\(eventID)")))]
        return provider
    }
    
    private func makeReminder(eventID: String = "$event:example.org",
                              actionKind: NitroReminderActionKind = .notify) -> NitroReminder {
        .init(id: "reminder-1",
              userID: "@alice:example.org",
              homeserverURL: "https://matrix.example.org",
              roomID: "!room:example.org",
              roomName: "Nitro team",
              eventID: eventID,
              threadRootID: nil,
              dueTimestamp: 1_700_000_200,
              label: "in 20 minutes",
              permalink: "https://matrix.to/#/!room:example.org/$event:example.org",
              createdTimestamp: 1_700_000_000,
              deliveredTimestamp: nil,
              updatedTimestamp: nil,
              status: .pending,
              error: nil,
              actionKind: actionKind)
    }
}
