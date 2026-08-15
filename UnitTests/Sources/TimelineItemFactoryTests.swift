//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import SwiftUI
import Testing

@MainActor
struct TimelineItemFactoryTests {
    @Test
    func callInvite() throws {
        let ownUserID = "@alice:matrix.org"
        let senderUserID = "@bob:matrix.org"
        
        let factory = RoomTimelineItemFactory(userID: ownUserID,
                                              attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                              stateEventStringBuilder: RoomStateEventStringBuilder(userID: ownUserID))
        
        let eventTimelineItem = EventTimelineItem.mockCallInvite(sender: senderUserID)
        
        let eventTimelineItemProxy = EventTimelineItemProxy(item: eventTimelineItem, uniqueID: .init("0"))
        
        let item = try #require(factory.buildTimelineItem(for: eventTimelineItemProxy, isDM: false) as? CallInviteRoomTimelineItem,
                                "Incorrect item type")
        
        #expect(item.isReactable == false)
        #expect(item.canBeRepliedTo == false)
        #expect(item.isEditable == false)
        #expect(item.sender == TimelineItemSender(id: senderUserID))
        #expect(item.properties.isEdited == false)
        #expect(item.properties.reactions == [])
        #expect(item.properties.deliveryStatus == nil)
    }
    
    @Test
    func sanitizedCustomEmojiMessageProducesAttachment() throws {
        let body = "Look :meatspin: now"
        let html = #"Look <img src="mxc://example.org/meatspin" alt="Meatspin" title="meatspin" height="32" /> now"#
        let messageType = MessageType.text(content: .init(body: body, formatted: .init(format: .html, body: html)))
        let content = TimelineItemContent.msgLike(content: .init(kind: .message(content: .init(msgType: messageType,
                                                                                               body: body,
                                                                                               isEdited: false,
                                                                                               mentions: nil)),
                                                                 reactions: [],
                                                                 inReplyTo: nil,
                                                                 threadRoot: nil,
                                                                 threadSummary: nil))
        let event = EventTimelineItem(configuration: .init(sender: "@alice:matrix.org", isOwn: true, content: content))
        let eventProxy = EventTimelineItemProxy(item: event, uniqueID: .init("custom-emoji"))
        let factory = RoomTimelineItemFactory(userID: "@alice:matrix.org",
                                              attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                              stateEventStringBuilder: RoomStateEventStringBuilder(userID: "@alice:matrix.org"))
        
        let item = try #require(factory.buildTimelineItem(for: eventProxy, isDM: false) as? TextRoomTimelineItem)
        let formattedBody = try #require(item.content.formattedBody)
        let attachments: [PillTextAttachment] = formattedBody.runs.compactMap { run in
            run.attachment as? PillTextAttachment
        }
        
        #expect(attachments.map(\.pillData.type) == [
            .customEmoji(urlString: "mxc://example.org/meatspin", alt: "Meatspin", shortcode: "meatspin")
        ])
        #expect(!String(formattedBody.characters).contains("[img:"))
    }
    
    @Test
    func sanitizedCustomEmojiMediaCaptionProducesAttachment() throws {
        let body = "Look :meatspin: now"
        let html = #"Look <img src="mxc://example.org/meatspin" alt="Meatspin" title="meatspin" height="32" /> now"#
        let source = try MediaSource.fromUrl(url: "mxc://example.org/image")
        let messageType = MessageType.image(content: .init(filename: "image.jpg",
                                                           caption: body,
                                                           formattedCaption: .init(format: .html, body: html),
                                                           source: source,
                                                           info: nil))
        let factory = RoomTimelineItemFactory(userID: "@alice:matrix.org",
                                              attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                              stateEventStringBuilder: RoomStateEventStringBuilder(userID: "@alice:matrix.org"))
        
        let content = factory.buildMessageTimelineItemContent(messageType: messageType,
                                                              senderID: "@alice:matrix.org",
                                                              senderDisplayName: nil)
        guard case .image(let imageContent) = content else {
            Issue.record("Incorrect content type")
            return
        }
        
        try expectCustomEmoji(in: imageContent.formattedCaption)
    }
    
    @Test
    func sanitizedCustomEmojiGalleryCaptionProducesAttachment() throws {
        let body = "Look :meatspin: now"
        let html = #"Look <img src="mxc://example.org/meatspin" alt="Meatspin" title="meatspin" height="32" /> now"#
        let messageType = MessageType.gallery(content: .init(body: body,
                                                             formatted: .init(format: .html, body: html),
                                                             itemtypes: []))
        let factory = RoomTimelineItemFactory(userID: "@alice:matrix.org",
                                              attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()),
                                              stateEventStringBuilder: RoomStateEventStringBuilder(userID: "@alice:matrix.org"))
        
        let content = factory.buildMessageTimelineItemContent(messageType: messageType,
                                                              senderID: "@alice:matrix.org",
                                                              senderDisplayName: nil)
        guard case .gallery(let galleryContent) = content else {
            Issue.record("Incorrect content type")
            return
        }
        
        try expectCustomEmoji(in: galleryContent.formattedCaption)
    }
    
    private func expectCustomEmoji(in attributedString: AttributedString?) throws {
        let attributedString = try #require(attributedString)
        let attachments: [PillTextAttachment] = attributedString.runs.compactMap { run in
            run.attachment as? PillTextAttachment
        }
        
        #expect(attachments.map(\.pillData.type) == [
            .customEmoji(urlString: "mxc://example.org/meatspin", alt: "Meatspin", shortcode: "meatspin")
        ])
        #expect(!String(attributedString.characters).contains("[img:"))
    }
}
