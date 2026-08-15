//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import MatrixRustSDK
import SwiftSoup
import SwiftUI
import WysiwygComposer

enum ComposerToolbarVoiceMessageAction {
    case startRecording
    case stopRecording
    case cancelRecording
    case deleteRecording
    case startPlayback
    case pausePlayback
    case scrubPlayback(scrubbing: Bool)
    case seekPlayback(progress: Double)
    case transcribe
    case send
}

enum ComposerToolbarViewModelAction {
    case sendMessage(plain: String, html: String?, mode: ComposerMode, intentionalMentions: IntentionalMentions)
    case editLastMessage
    case attach(ComposerAttachmentType)
    
    case handlePasteOrDrop(providers: [NSItemProvider])
    
    case composerModeChanged(mode: ComposerMode)
    case composerFocusedChanged(isFocused: Bool)
    
    case voiceMessage(ComposerToolbarVoiceMessageAction)
    
    case contentChanged(isEmpty: Bool)
}

enum ComposerToolbarViewAction {
    case composerAppeared
    case composerDisappeared
    
    case sendMessage
    case editLastMessage
    case cancelReply
    case cancelEdit
    case attach(ComposerAttachmentType)
    case handlePasteOrDrop(providers: [NSItemProvider])
    case enableTextFormatting
    case composerAction(action: ComposerAction)
    case selectedSuggestion(_ suggestion: SuggestionItem)
    
    case voiceMessage(ComposerToolbarVoiceMessageAction)
}

enum ComposerAttachmentType {
    case camera
    case customEmoji
    case photoLibrary
    case file
    case location
    case poll
}

struct ComposerToolbarViewState: BindableState {
    let wysiwygViewModel: WysiwygComposerViewModel
    
    var composerMode: ComposerMode = .default
    var composerEmpty = true
    var isResolvingCustomEmojis = false
    /// Could be false if sending is disabled in the room
    var canSend = true
    var suggestions: [SuggestionItem] = []
    
    var isRoomEncrypted: Bool
    var isLocationSharingEnabled: Bool
    
    var keyCommands: [WysiwygKeyCommand] = []
    
    var canSendStandaloneEmoji: Bool {
        canSend && composerEmpty && composerMode.isComposingNewMessage
    }
    
    var bindings: ComposerToolbarViewStateBindings
    
    var isUploading: Bool {
        switch composerMode {
        case .previewVoiceMessage(_, _, let isUploading):
            return isUploading
        default:
            return false
        }
    }
    
    var showSendButton: Bool {
        switch composerMode {
        case .recordVoiceMessage:
            return false
        case .previewVoiceMessage:
            return true
        default:
            return !composerEmpty
        }
    }
    
    var sendButtonMode: SendButton.Mode {
        composerMode.isEdit ? .edit : .send
    }
    
    var sendButtonAccessibilityLabel: String {
        composerMode.isEdit ? L10n.actionConfirm : L10n.actionSend
    }
    
    var sendButtonDisabled: Bool {
        if !canSend || isResolvingCustomEmojis {
            return true
        }
        
        if case .previewVoiceMessage = composerMode {
            return false
        }
        
        return composerEmpty
    }
    
    var isVoiceMessageModeActivated: Bool {
        switch composerMode {
        case .recordVoiceMessage, .previewVoiceMessage:
            return true
        default:
            return false
        }
    }
}

nonisolated struct CustomEmojiMessageContent: Equatable {
    private static let plainTextDraftPrefix = "<!-- io.element.elementx.plain-custom-emoji-draft -->"
    
    struct Restoration: Equatable {
        let html: String
        let customEmojis: [CustomEmoji]
    }
    
    private struct ParsedCustomEmoji {
        let emoji: CustomEmoji
        let isMarked: Bool
    }
    
    let plain: String
    let html: String?
    
    init(emoji: CustomEmoji) {
        plain = ":\(emoji.shortcode):"
        html = Self.imageTag(for: emoji)
    }
    
    static func containsPotentialShortcode(in string: String) -> Bool {
        string.firstMatch(of: /:[+\-\w]+:/) != nil
    }
    
    /// Returns nil when the HTML doesn't contain a recognised shortcode.
    static func renderingCustomEmojis(in html: String, customEmojis: [CustomEmoji]) -> String? {
        var emojisByShortcode = [String: CustomEmoji]()
        for emoji in customEmojis where emojisByShortcode[emoji.shortcode] == nil {
            emojisByShortcode[emoji.shortcode] = emoji
        }
        guard !emojisByShortcode.isEmpty else { return nil }
        
        let transformation = transformHTML(html) { text in
            replacingShortcodes(in: text, emojisByShortcode: emojisByShortcode)
        } transformTag: { _ in
            nil
        }
        return transformation.changed ? transformation.html : nil
    }
    
    static func renderingCustomEmojis(inPlainText text: String, customEmojis: [CustomEmoji]) -> String? {
        let html = escapeHTML(text).replacingOccurrences(of: "\n", with: "<br />")
        return renderingCustomEmojis(in: html, customEmojis: customEmojis)
    }
    
    static func restoringShortcodes(in html: String, fallbackBody: String? = nil) -> String {
        restoringCustomEmojis(in: html, fallbackBody: fallbackBody).html
    }
    
    static func restoringCustomEmojis(in html: String, fallbackBody: String? = nil) -> Restoration {
        var customEmojis = [CustomEmoji]()
        var remainingFallbackShortcodes = [String: Int]()
        let transformation = transformHTML(html) { text in
            (text, false)
        } transformTag: { tag in
            guard let parsedEmoji = customEmoji(from: tag) else { return nil }
            let emoji = parsedEmoji.emoji
            guard parsedEmoji.isMarked || consumeFallbackShortcode(emoji.shortcode,
                                                                   fallbackBody: fallbackBody,
                                                                   remainingShortcodes: &remainingFallbackShortcodes) else { return nil }
            customEmojis.append(emoji)
            return ":\(emoji.shortcode):"
        }
        return Restoration(html: transformation.html, customEmojis: customEmojis)
    }
    
    static func markingPlainTextDraft(_ html: String) -> String {
        plainTextDraftPrefix + html
    }
    
    static func unmarkingPlainTextDraft(_ html: String) -> String? {
        guard html.hasPrefix(plainTextDraftPrefix) else { return nil }
        return String(html.dropFirst(plainTextDraftPrefix.count))
    }
    
    private static let excludedTextTags: Set = ["a", "code", "pre", "script", "style", "textarea"]
    private static let voidTags: Set = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    
    private struct HTMLTagInfo {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
    }
    
    private static func transformHTML(_ html: String,
                                      transformText: (String) -> (text: String, changed: Bool),
                                      transformTag: (String) -> String?) -> (html: String, changed: Bool) {
        var output = ""
        var cursor = html.startIndex
        var excludedTagStack = [String]()
        var changed = false
        
        while cursor < html.endIndex {
            if html[cursor] == "<", findTagEnd(in: html, from: cursor) == nil {
                let text = String(html[cursor...])
                if excludedTagStack.isEmpty {
                    let transformed = transformText(text)
                    output += transformed.text
                    changed = changed || transformed.changed
                } else {
                    output += text
                }
                break
            }
            
            guard html[cursor] == "<",
                  let tagEnd = findTagEnd(in: html, from: cursor) else {
                let nextTag = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                let text = String(html[cursor..<nextTag])
                if excludedTagStack.isEmpty {
                    let transformed = transformText(text)
                    output += transformed.text
                    changed = changed || transformed.changed
                } else {
                    output += text
                }
                cursor = nextTag
                continue
            }
            
            let afterTag = html.index(after: tagEnd)
            let tag = String(html[cursor..<afterTag])
            if let replacement = transformTag(tag) {
                output += replacement
                changed = true
                cursor = afterTag
                continue
            }
            
            output += tag
            if let info = tagInfo(from: tag), excludedTextTags.contains(info.name) {
                if info.isClosing {
                    if let index = excludedTagStack.lastIndex(of: info.name) {
                        excludedTagStack.remove(at: index)
                    }
                } else if !info.isSelfClosing, !voidTags.contains(info.name) {
                    excludedTagStack.append(info.name)
                }
            }
            cursor = afterTag
        }
        
        return (output, changed)
    }
    
    private static func replacingShortcodes(in text: String,
                                            emojisByShortcode: [String: CustomEmoji]) -> (text: String, changed: Bool) {
        var output = ""
        var cursor = text.startIndex
        var changed = false
        
        for match in text.matches(of: /:[+\-\w]+:/) {
            output += text[cursor..<match.range.lowerBound]
            let token = String(text[match.range])
            let shortcode = String(token.dropFirst().dropLast())
            if let emoji = emojisByShortcode[shortcode] {
                output += imageTag(for: emoji)
                changed = true
            } else {
                output += token
            }
            cursor = match.range.upperBound
        }
        output += text[cursor...]
        return (output, changed)
    }
    
    private static func findTagEnd(in html: String, from start: String.Index) -> String.Index? {
        var index = html.index(after: start)
        var quote: Character?
        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }
    
    private static func tagInfo(from tag: String) -> HTMLTagInfo? {
        guard tag.first == "<", tag.last == ">" else { return nil }
        var contents = tag.dropFirst().dropLast().drop { $0.isWhitespace }
        guard contents.first != "!", contents.first != "?" else { return nil }
        
        let isClosing = contents.first == "/"
        if isClosing {
            contents = contents.dropFirst().drop { $0.isWhitespace }
        }
        let name = contents.prefix { $0.isLetter || $0.isNumber }.lowercased()
        guard !name.isEmpty else { return nil }
        let isSelfClosing = tag.dropLast().drop { $0.isWhitespace }.last == "/"
        return HTMLTagInfo(name: name,
                           isClosing: isClosing,
                           isSelfClosing: isSelfClosing)
    }
    
    private static func customEmoji(from tag: String) -> ParsedCustomEmoji? {
        guard let document = try? SwiftSoup.parseBodyFragment(tag),
              let element = document.body()?.children().first(),
              element.tagName().caseInsensitiveCompare("img") == .orderedSame,
              let rawURL = try? element.attr("src"),
              let imageURL = URL(string: decodeHTMLEntities(rawURL)),
              imageURL.scheme == "mxc",
              imageURL.host != nil else {
            return nil
        }
        let isMarked = element.hasAttr("data-mx-emoticon")
        let title = try? element.attr("title")
        let alt = try? element.attr("alt")
        let rawValue: String
        if let title, !title.isEmpty {
            rawValue = title
        } else if isMarked, let alt, !alt.isEmpty {
            rawValue = alt
        } else {
            return nil
        }
        
        let decodedValue = decodeHTMLEntities(rawValue)
        let shortcode = if decodedValue.first == ":", decodedValue.last == ":", decodedValue.count > 2 {
            String(decodedValue.dropFirst().dropLast())
        } else {
            decodedValue
        }
        guard !shortcode.isEmpty,
              shortcode.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" }) else {
            return nil
        }
        let decodedAlt = alt.map(decodeHTMLEntities)
        let body = decodedAlt.flatMap { $0.isEmpty ? nil : $0 } ?? shortcode
        return ParsedCustomEmoji(emoji: CustomEmoji(shortcode: shortcode, body: body, imageURL: imageURL),
                                 isMarked: isMarked)
    }
    
    private static func nonOverlappingOccurrences(of token: String, in string: String) -> Int {
        var count = 0
        var searchRange = string.startIndex..<string.endIndex
        while let match = string.range(of: token, range: searchRange) {
            count += 1
            searchRange = match.upperBound..<string.endIndex
        }
        return count
    }
    
    private static func consumeFallbackShortcode(_ shortcode: String,
                                                 fallbackBody: String?,
                                                 remainingShortcodes: inout [String: Int]) -> Bool {
        guard let fallbackBody else { return false }
        if remainingShortcodes[shortcode] == nil {
            remainingShortcodes[shortcode] = nonOverlappingOccurrences(of: ":\(shortcode):", in: fallbackBody)
        }
        guard remainingShortcodes[shortcode, default: 0] > 0 else { return false }
        remainingShortcodes[shortcode, default: 0] -= 1
        return true
    }
    
    private static func imageTag(for emoji: CustomEmoji) -> String {
        "<img data-mx-emoticon src=\"\(escapeHTML(emoji.imageURL.absoluteString))\" alt=\"\(escapeHTML(emoji.body))\" title=\"\(escapeHTML(emoji.shortcode))\" height=\"32\" />"
    }
    
    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    
    private static func decodeHTMLEntities(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

struct ComposerToolbarViewStateBindings {
    var plainComposerText: NSAttributedString = .init(string: "")
    var composerFocused = false
    var composerFormattingEnabled = false
    var composerExpanded = false
    var formatItems: [FormatItem] = .init()
    var alertInfo: AlertInfo<UUID>?
    var selectedRange = NSRange(location: 0, length: 0)
}

/// An item in the toolbar
struct FormatItem {
    /// The type of the item
    let type: FormatType
    /// The state of the item
    let state: ActionState
}

/// The types of formatting actions
enum FormatType {
    case bold
    case italic
    case underline
    case strikeThrough
    case link
    case unorderedList
    case orderedList
    case indent
    case unindent
    case inlineCode
    case codeBlock
    case quote
}

extension FormatType: CaseIterable, Identifiable {
    var id: Self {
        self
    }
}

extension FormatItem: Identifiable {
    var id: FormatType {
        type
    }
}

extension FormatItem {
    /// The icon to display in the formatting toolbar.
    var icon: KeyPath<CompoundIcons, Image> {
        switch type {
        case .bold:
            return \.bold
        case .italic:
            return \.italic
        case .underline:
            return \.underline
        case .strikeThrough:
            return \.strikethrough
        case .unorderedList:
            return \.listBulleted
        case .orderedList:
            return \.listNumbered
        case .indent:
            return \.indentIncrease
        case .unindent:
            return \.indentDecrease
        case .inlineCode:
            return \.inlineCode
        case .codeBlock:
            return \.code
        case .quote:
            return \.quote
        case .link:
            return \.link
        }
    }
    
    var accessibilityIdentifier: String {
        switch type {
        case .bold:
            return A11yIdentifiers.roomScreen.composerToolbar.bold
        case .italic:
            return A11yIdentifiers.roomScreen.composerToolbar.italic
        case .underline:
            return A11yIdentifiers.roomScreen.composerToolbar.underline
        case .strikeThrough:
            return A11yIdentifiers.roomScreen.composerToolbar.strikethrough
        case .unorderedList:
            return A11yIdentifiers.roomScreen.composerToolbar.unorderedList
        case .orderedList:
            return A11yIdentifiers.roomScreen.composerToolbar.orderedList
        case .indent:
            return A11yIdentifiers.roomScreen.composerToolbar.indent
        case .unindent:
            return A11yIdentifiers.roomScreen.composerToolbar.unindent
        case .inlineCode:
            return A11yIdentifiers.roomScreen.composerToolbar.inlineCode
        case .codeBlock:
            return A11yIdentifiers.roomScreen.composerToolbar.codeBlock
        case .quote:
            return A11yIdentifiers.roomScreen.composerToolbar.quote
        case .link:
            return A11yIdentifiers.roomScreen.composerToolbar.link
        }
    }
    
    var accessibilityLabel: String {
        let localizedAction = switch type {
        case .bold:
            L10n.richTextEditorFormatBold
        case .italic:
            L10n.richTextEditorFormatItalic
        case .underline:
            L10n.richTextEditorFormatUnderline
        case .strikeThrough:
            L10n.richTextEditorFormatStrikethrough
        case .unorderedList:
            L10n.richTextEditorBulletList
        case .orderedList:
            L10n.richTextEditorNumberedList
        case .indent:
            L10n.richTextEditorIndent
        case .unindent:
            L10n.richTextEditorUnindent
        case .inlineCode:
            L10n.richTextEditorInlineCode
        case .codeBlock:
            L10n.richTextEditorCodeBlock
        case .quote:
            L10n.richTextEditorQuote
        case .link:
            L10n.richTextEditorLink
        }
        return L10n.richTextEditorFormatAction(localizedAction, state.localizedDescription)
    }
}

extension ActionState {
    /// Returns a localized string that describes the action state.
    var localizedDescription: String {
        switch self {
        case .disabled:
            L10n.richTextEditorFormatStateDisabled
        case .enabled:
            L10n.richTextEditorFormatStateOff
        case .reversed:
            L10n.richTextEditorFormatStateOn
        }
    }
}

extension FormatType {
    /// The associated library composer action.
    var composerAction: ComposerAction {
        switch self {
        case .bold:
            return .bold
        case .italic:
            return .italic
        case .underline:
            return .underline
        case .strikeThrough:
            return .strikeThrough
        case .unorderedList:
            return .unorderedList
        case .orderedList:
            return .orderedList
        case .indent:
            return .indent
        case .unindent:
            return .unindent
        case .inlineCode:
            return .inlineCode
        case .codeBlock:
            return .codeBlock
        case .quote:
            return .quote
        case .link:
            return .link
        }
    }
}

enum ComposerMode: Equatable {
    enum EditType { case `default`, addCaption, editCaption }
    
    case `default`
    case reply(eventID: String, replyDetails: TimelineItemReplyDetails, isThread: Bool)
    case edit(originalEventOrTransactionID: TimelineItemIdentifier.EventOrTransactionID, type: EditType)
    case recordVoiceMessage(state: AudioRecorderState)
    case previewVoiceMessage(state: AudioPlayerState, waveform: WaveformSource, isUploading: Bool)
    
    var isEdit: Bool {
        switch self {
        case .edit:
            return true
        default:
            return false
        }
    }
    
    var isTextEditingEnabled: Bool {
        switch self {
        case .default, .reply, .edit:
            return true
        case .recordVoiceMessage, .previewVoiceMessage:
            return false
        }
    }
    
    var isLoadingReply: Bool {
        switch self {
        case .reply(_, let replyDetails, _):
            switch replyDetails {
            case .loading:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }
    
    var replyEventID: String? {
        switch self {
        case .reply(let eventID, _, _):
            return eventID
        default:
            return nil
        }
    }
    
    var isComposingNewMessage: Bool {
        switch self {
        case .default, .reply:
            return true
        default:
            return false
        }
    }
}
