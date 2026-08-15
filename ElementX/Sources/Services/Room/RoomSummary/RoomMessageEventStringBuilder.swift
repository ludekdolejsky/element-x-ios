//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK
import SwiftSoup

nonisolated struct RoomMessageEventStringBuilder {
    enum Style {
        /// Plain: no prefix, no special text treatment
        /// Shown in push notifications and thread lists
        case plain
        /// Strings show on the room list as the last message
        /// The sender will be prefixed in bold
        case senderPrefixed
        /// Events pinned to the banner on the top of the timeline
        /// The message type will be prefixed in bold
        case typeBolded
    }
    
    let attributedStringBuilder: AttributedStringBuilderProtocol
    let style: Style
    
    func buildAttributedString(for messageType: MessageType, senderDisplayName: String, isOutgoing: Bool) -> AttributedString {
        let message: AttributedString
        switch messageType {
        case .emote(content: let content):
            if let attributedMessage = attributedMessageFrom(formattedBody: content.formatted, fallbackBody: content.body) {
                return AttributedString(L10n.commonEmote(senderDisplayName, String(attributedMessage.characters)))
            } else {
                return AttributedString(L10n.commonEmote(senderDisplayName, content.body))
            }
        case .audio(content: let content):
            let isVoiceMessage = content.voice != nil
            var content = AttributedString(isVoiceMessage ? L10n.commonVoiceMessage : L10n.commonAudio)
            if style == .typeBolded {
                content.bold()
            }
            message = content
        case .image(let content):
            message = buildMessage(for: style, caption: content.caption, type: L10n.commonImage)
        case .video(let content):
            message = buildMessage(for: style, caption: content.caption, type: L10n.commonVideo)
        case .file(let content):
            message = buildMessage(for: style, caption: content.caption, type: L10n.commonFile)
        case .location:
            var content = AttributedString(L10n.commonSharedLocation)
            if style == .typeBolded {
                content.bold()
            }
            message = content
        case .notice(content: let content):
            if let attributedMessage = attributedMessageFrom(formattedBody: content.formatted, fallbackBody: content.body) {
                message = attributedMessage
            } else {
                message = AttributedString(content.body)
            }
        case .text(content: let content):
            if let attributedMessage = attributedMessageFrom(formattedBody: content.formatted, fallbackBody: content.body) {
                message = attributedMessage
            } else {
                message = AttributedString(content.body)
            }
        case .gallery(let content):
            message = buildGalleryMessage(for: style, content: content)
        case .other(_, let body):
            message = AttributedString(body)
        }
        
        if style == .senderPrefixed {
            return prefix(message, with: isOutgoing ? L10n.commonYou : senderDisplayName)
        } else {
            return message
        }
    }
    
    func buildAttributedStringForLiveLocation(senderDisplayName: String, isOutgoing: Bool) -> AttributedString {
        var message = AttributedString(L10n.commonSharedLiveLocation)
        if style == .typeBolded {
            message.bold()
        }
        
        if style == .senderPrefixed {
            return prefix(message, with: isOutgoing ? L10n.commonYou : senderDisplayName)
        } else {
            return message
        }
    }
    
    /// A gallery's body is its caption. Notifications fall back to counting the attachments when
    /// there isn't one, whilst elsewhere it is treated as any other media's caption.
    private func buildGalleryMessage(for style: Style, content: GalleryMessageContent) -> AttributedString {
        switch style {
        case .plain:
            if content.body.isBlank {
                AttributedString(L10n.notificationGalleryBody(content.itemtypes.count))
            } else {
                AttributedString(content.body)
            }
        case .senderPrefixed, .typeBolded:
            buildMessage(for: style, caption: content.body, type: L10n.commonGallery)
        }
    }
    
    private func buildMessage(for style: Style, caption: String?, type: String) -> AttributedString {
        guard let caption, !caption.isBlank else {
            return AttributedString(type)
        }
        
        if style == .typeBolded {
            return prefix(AttributedString(caption), with: type)
        } else {
            return AttributedString("\(type) - \(caption)")
        }
    }
    
    private func prefix(_ eventSummary: AttributedString, with textToBold: String) -> AttributedString {
        let attributedEventSummary = AttributedString(eventSummary.string.trimmingCharacters(in: .whitespacesAndNewlines))
        
        var attributedPrefix = AttributedString(textToBold + ":")
        attributedPrefix.bold()
        
        // Don't include the message body in the markdown otherwise it makes tappable links.
        return attributedPrefix + " " + attributedEventSummary
    }
    
    private func attributedMessageFrom(formattedBody: FormattedBody?, fallbackBody: String) -> AttributedString? {
        guard let formattedBody else { return nil }
        
        // Room, thread and notification previews are textual. Replace custom
        // emoji media with its shortcode while preserving other HTML formatting.
        if let previewHTML = replacingCustomEmoji(in: formattedBody.body, fallbackBody: fallbackBody) {
            return attributedStringBuilder.fromHTML(previewHTML)
        }
        
        return attributedStringBuilder.fromHTML(formattedBody.body)
    }
    
    private func replacingCustomEmoji(in html: String, fallbackBody: String) -> String? {
        guard let document = try? SwiftSoup.parseBodyFragment(html),
              let body = document.body(),
              let images = try? body.select("img") else {
            return nil
        }
        
        var replacedImage = false
        for image in images {
            guard let source = try? image.attr("src"),
                  let url = URL(string: source),
                  url.scheme == "mxc",
                  url.host != nil else {
                continue
            }
            
            guard let title = try? image.attr("title"), !title.isEmpty else {
                continue
            }
            let shortcode = if title.hasPrefix(":"), title.hasSuffix(":"), title.count > 2 {
                String(title.dropFirst().dropLast())
            } else {
                title
            }
            guard image.hasAttr("data-mx-emoticon") || fallbackBody.contains(":\(shortcode):") else {
                continue
            }
            
            do {
                try image.replaceWith(TextNode(":\(shortcode):", nil))
                replacedImage = true
            } catch {
                continue
            }
        }
        
        guard replacedImage else { return nil }
        return try? body.html()
    }
}
