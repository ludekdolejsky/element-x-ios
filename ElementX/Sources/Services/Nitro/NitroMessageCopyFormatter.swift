//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import UIKit
import UniformTypeIdentifiers
import WysiwygComposer

enum NitroMessageCopyFormatter {
    static let markdownTypeIdentifier = "net.daringfireball.markdown"

    enum Format {
        case text
        case markdown
        case html
    }

    enum RichPasteContent: Equatable {
        case html(String, plainText: String)
        case markdown(String)

        var plainText: String {
            switch self {
            case .html(_, let plainText):
                plainText
            case .markdown(let markdown):
                markdown
            }
        }
    }

    static func pasteboardRepresentations(for item: EventBasedMessageTimelineItemProtocol, format: Format) -> [String: Any] {
        switch format {
        case .text:
            let content = renderedContent(for: item)
            var representations: [String: Any] = [
                UTType.utf8PlainText.identifier: content.plainText,
                UTType.html.identifier: content.html,
                markdownTypeIdentifier: content.markdown
            ]
            if let rtf = rtfData(from: content.attributedString) {
                representations[UTType.rtf.identifier] = rtf
            }
            return representations
        case .markdown:
            return [UTType.utf8PlainText.identifier: markdown(for: item)]
        case .html:
            return [UTType.utf8PlainText.identifier: html(for: item)]
        }
    }

    static func supportsRichPaste(_ itemProvider: NSItemProvider) -> Bool {
        return itemProvider.hasItemConformingToTypeIdentifier(UTType.html.identifier) ||
            itemProvider.hasItemConformingToTypeIdentifier(markdownTypeIdentifier)
    }

    static func richPasteContent(from pasteboard: UIPasteboard) -> RichPasteContent? {
        if let html = string(from: pasteboard, type: UTType.html.identifier) {
            let plainText = string(from: pasteboard, type: UTType.utf8PlainText.identifier) ?? renderedContent(forHTML: html).plainText
            return .html(html, plainText: plainText)
        }

        if let markdown = string(from: pasteboard, type: markdownTypeIdentifier) {
            return .markdown(markdown)
        }

        return nil
    }

    private static func string(from pasteboard: UIPasteboard, type: String) -> String? {
        if let string = pasteboard.value(forPasteboardType: type) as? String {
            return string
        }

        guard let data = pasteboard.data(forPasteboardType: type) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode)
    }

    static func markdown(for item: EventBasedMessageTimelineItemProtocol) -> String {
        guard let html = formattedBodyHTML(for: item) else { return item.body }
        return renderedContent(forHTML: html, fallbackBody: item.body).markdown
    }

    static func html(for item: EventBasedMessageTimelineItemProtocol) -> String {
        formattedBodyHTML(for: item) ?? item.body
    }

    private struct RenderedContent {
        let plainText: String
        let html: String
        let markdown: String
        let attributedString: NSAttributedString
    }

    private static func renderedContent(for item: EventBasedMessageTimelineItemProtocol) -> RenderedContent {
        guard let html = formattedBodyHTML(for: item) else {
            return .init(plainText: item.body,
                         html: htmlForPlainText(item.body),
                         markdown: item.body,
                         attributedString: .init(string: item.body))
        }
        return renderedContent(forHTML: html, fallbackBody: item.body)
    }
    
    private static func renderedContent(forHTML html: String, fallbackBody: String? = nil) -> RenderedContent {
        let wysiwygHTML = CustomEmojiMessageContent.restoringShortcodes(in: html, fallbackBody: fallbackBody)
        let viewModel = WysiwygComposerViewModel()
        viewModel.setHtmlContent(wysiwygHTML)
        return .init(plainText: viewModel.attributedContent.text.string,
                     html: html,
                     markdown: desktopCompatibleMarkdown(viewModel.content.markdown),
                     attributedString: viewModel.attributedContent.text)
    }

    private static func htmlForPlainText(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<p>\(escaped)</p>"
    }

    private static func rtfData(from attributedString: NSAttributedString) -> Data? {
        try? attributedString.data(from: NSRange(location: 0, length: attributedString.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
    
    private static func formattedBodyHTML(for item: EventBasedMessageTimelineItemProtocol) -> String? {
        switch item.contentType {
        case .text(let content):
            content.formattedBodyHTMLString
        case .notice(let content):
            content.formattedBodyHTMLString
        case .emote(let content):
            content.formattedBodyHTMLString
        case .audio, .file, .image, .video, .location, .voice, .gallery:
            nil
        }
    }
    
    private static func desktopCompatibleMarkdown(_ markdown: String) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var result = [String]()
        var activeFence: (marker: Character, length: Int)?
        
        for rawLine in lines {
            let rawLine = String(rawLine)
            if let fence = activeFence {
                result.append(rawLine)
                if isClosingFence(rawLine, matching: fence) {
                    activeFence = nil
                }
                continue
            }
            
            let line = normalizeBulletMarker(rawLine)
            if let previousLine = result.last,
               !line.isEmpty,
               !previousLine.isEmpty,
               isListItem(line) != isListItem(previousLine) {
                result.append("")
            }
            result.append(line)
            activeFence = openingFence(in: rawLine)
        }
        
        return result.joined(separator: "\n")
    }
    
    private static func normalizeBulletMarker(_ line: String) -> String {
        let contentStart = line.firstIndex { !$0.isWhitespace } ?? line.endIndex
        let indentation = line[..<contentStart]
        let content = line[contentStart...]
        guard content.hasPrefix("* ") else { return String(line) }
        return "\(indentation)- \(content.dropFirst(2))"
    }
    
    private static func openingFence(in line: String) -> (marker: Character, length: Int)? {
        let content = line.drop { $0.isWhitespace }
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let length = content.prefix { $0 == marker }.count
        return length >= 3 ? (marker, length) : nil
    }
    
    private static func isClosingFence(_ line: String, matching fence: (marker: Character, length: Int)) -> Bool {
        let content = line.drop { $0.isWhitespace }
        let markerLength = content.prefix { $0 == fence.marker }.count
        return markerLength >= fence.length && content.dropFirst(markerLength).allSatisfy(\.isWhitespace)
    }
    
    private static func isListItem(_ line: String) -> Bool {
        let content = line.drop { $0.isWhitespace }
        return content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ")
    }
}
