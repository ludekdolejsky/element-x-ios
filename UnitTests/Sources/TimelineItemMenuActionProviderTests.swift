//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct TimelineItemMenuActionProviderTests {
    @Test
    func textualMessagesOfferCopySubmenu() throws {
        let item = TextRoomTimelineItem(id: .randomEvent,
                                        timestamp: Date(),
                                        isOutgoing: false,
                                        isEditable: false,
                                        canBeRepliedTo: true,
                                        sender: .init(id: "@alice:example.org", displayName: "Alice"),
                                        content: .init(body: "Formatted message"))
        let provider = TimelineItemMenuActionProvider(timelineItem: item,
                                                      canCurrentUserSendMessage: false,
                                                      canCurrentUserRedactSelf: false,
                                                      canCurrentUserRedactOthers: false,
                                                      canCurrentUserPin: false,
                                                      pinnedEventIDs: [],
                                                      isViewSourceEnabled: false,
                                                      areThreadsEnabled: true,
                                                      timelineKind: .live,
                                                      emojiProvider: EmojiProvider(appSettings: .volatile()))
        let actions = try #require(provider.makeActions()).actions
        #expect(actions.contains(.copy))
        #expect(!actions.contains(.copyAsMarkdown))
        #expect(!actions.contains(.copyAsHTML))
        #expect(TimelineItemMenuAction.copy.submenuActions == [.copy, .copyAsMarkdown, .copyAsHTML])
    }
    
    @Test
    func addTaskRequiresSendAndPinPermissions() throws {
        let item = TextRoomTimelineItem(id: .randomEvent,
                                        timestamp: Date(),
                                        isOutgoing: false,
                                        isEditable: false,
                                        canBeRepliedTo: true,
                                        sender: .init(id: "@alice:example.org", displayName: "Alice"),
                                        content: .init(body: "Create a task"))
        let emojiProvider = EmojiProvider(appSettings: .volatile())
        
        func actions(canSend: Bool, canPin: Bool) throws -> [TimelineItemMenuAction] {
            let provider = TimelineItemMenuActionProvider(timelineItem: item,
                                                          canCurrentUserSendMessage: canSend,
                                                          canCurrentUserRedactSelf: false,
                                                          canCurrentUserRedactOthers: false,
                                                          canCurrentUserPin: canPin,
                                                          pinnedEventIDs: [],
                                                          isViewSourceEnabled: false,
                                                          areThreadsEnabled: true,
                                                          timelineKind: .live,
                                                          emojiProvider: emojiProvider)
            return try #require(provider.makeActions()).actions
        }
        
        let cannotSend = try actions(canSend: false, canPin: true)
        let cannotPin = try actions(canSend: true, canPin: false)
        let canCreateTask = try actions(canSend: true, canPin: true)
        let noTaskPermissions = try actions(canSend: false, canPin: false)
        #expect(!cannotSend.contains(.addTask))
        #expect(!cannotPin.contains(.addTask))
        #expect(canCreateTask.contains(.addTask))
        #expect(noTaskPermissions.contains(.remindMe))
    }
}
