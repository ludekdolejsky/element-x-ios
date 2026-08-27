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
    private static let plainTextTypeIdentifiers = [
        UTType.utf8PlainText.identifier,
        UTType.utf16PlainText.identifier,
        UTType.utf16ExternalPlainText.identifier,
        UTType.plainText.identifier
    ]
    
    enum Format {
        case text
        case markdown
        case html
    }
    
    enum RichPasteContent: Equatable {
        case html(String, plainText: String)
        case markdown(String)
        case plainText(String)
        
        var plainText: String {
            switch self {
            case .html(_, let plainText):
                plainText
            case .markdown(let markdown):
                markdown
            case .plainText(let plainText):
                plainText
            }
        }
    }
    
    struct PasteDiagnostics {
        struct Representation {
            let typeIdentifier: String
            let conformsToText: Bool
            let byteCount: Int?
        }
        
        let supportsTextPaste: Bool
        let selectedTypeIdentifier: String?
        let selectedFormat: String?
        let representations: [Representation]
    }
    
    private struct ResolvedRichPasteContent {
        let content: RichPasteContent
        let typeIdentifier: String
        let format: String
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
            let markdown = markdown(for: item)
            return [
                UTType.utf8PlainText.identifier: markdown,
                markdownTypeIdentifier: markdown
            ]
        case .html:
            let html = html(for: item)
            let content = renderedContent(forHTML: html, fallbackBody: item.body)
            var representations: [String: Any] = [
                UTType.utf8PlainText.identifier: html,
                UTType.html.identifier: utf8HTMLDocument(for: html)
            ]
            if let rtf = rtfData(from: content.attributedString) {
                representations[UTType.rtf.identifier] = rtf
            }
            return representations
        }
    }
    
    static func supportsTextPaste(_ itemProvider: NSItemProvider) -> Bool {
        itemProvider.hasItemConformingToTypeIdentifier(UTType.html.identifier) ||
            itemProvider.hasItemConformingToTypeIdentifier(markdownTypeIdentifier) ||
            itemProvider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
    }
    
    static func richPasteContent(from itemProvider: NSItemProvider) async -> RichPasteContent? {
        await resolvedRichPasteContent(from: itemProvider)?.content
    }
    
    static func pasteDiagnostics(from itemProvider: NSItemProvider) async -> PasteDiagnostics {
        let resolution = await resolvedRichPasteContent(from: itemProvider)
        var representations = [PasteDiagnostics.Representation]()
        
        for typeIdentifier in itemProvider.registeredTypeIdentifiers {
            guard !Task.isCancelled else { break }
            let conformsToText = isTextType(typeIdentifier)
            let byteCount = conformsToText ? await dataRepresentation(from: itemProvider, type: typeIdentifier)?.count : nil
            representations.append(.init(typeIdentifier: typeIdentifier,
                                         conformsToText: conformsToText,
                                         byteCount: byteCount))
        }
        
        return .init(supportsTextPaste: supportsTextPaste(itemProvider),
                     selectedTypeIdentifier: resolution?.typeIdentifier,
                     selectedFormat: resolution?.format,
                     representations: representations)
    }
    
    private static func resolvedRichPasteContent(from itemProvider: NSItemProvider) async -> ResolvedRichPasteContent? {
        if itemProvider.hasItemConformingToTypeIdentifier(UTType.html.identifier),
           let html = await string(from: itemProvider, type: UTType.html.identifier) {
            let composerHTML = htmlBodyFragment(from: html) ?? html
            let renderedPlainText = renderedContent(forHTML: composerHTML).plainText
            let providedPlainText = await string(from: itemProvider, type: UTType.utf8PlainText.identifier)
            let providedPlainTextIsHTMLSource = providedPlainText == composerHTML || providedPlainText == html ||
                providedPlainText.map { utf8HTMLDocument(for: $0) == html } == true
            let plainText = providedPlainTextIsHTMLSource ? renderedPlainText : providedPlainText ?? renderedPlainText
            return .init(content: .html(composerHTML, plainText: plainText),
                         typeIdentifier: UTType.html.identifier,
                         format: "HTML")
        }
        
        if itemProvider.hasItemConformingToTypeIdentifier(markdownTypeIdentifier),
           let markdown = await string(from: itemProvider, type: markdownTypeIdentifier) {
            return .init(content: .markdown(markdown),
                         typeIdentifier: markdownTypeIdentifier,
                         format: "Markdown")
        }
        
        for type in plainTextTypeIdentifiers where itemProvider.registeredTypeIdentifiers.contains(type) {
            if let plainText = await string(from: itemProvider, type: type) {
                return .init(content: .plainText(plainText),
                             typeIdentifier: type,
                             format: "Plain text")
            }
        }
        
        if itemProvider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier),
           let data = await data(from: itemProvider, type: UTType.rtf.identifier),
           let plainText = await plainText(fromRTF: data) {
            return .init(content: .plainText(plainText),
                         typeIdentifier: UTType.rtf.identifier,
                         format: "RTF")
        }
        
        let registeredTypes = itemProvider.registeredTypeIdentifiers.filter {
            !plainTextTypeIdentifiers.contains($0) && $0 != UTType.rtf.identifier && isTextType($0)
        }
        for type in registeredTypes {
            if let plainText = await string(from: itemProvider, type: type) {
                return .init(content: .plainText(plainText),
                             typeIdentifier: type,
                             format: "Generic text")
            }
        }
        
        if itemProvider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
           let plainText = await string(from: itemProvider, type: UTType.text.identifier) {
            return .init(content: .plainText(plainText),
                         typeIdentifier: UTType.text.identifier,
                         format: "Conforming text fallback")
        }
        
        return nil
    }
    
    private static func isTextType(_ typeIdentifier: String) -> Bool {
        typeIdentifier == markdownTypeIdentifier ||
            UTType(typeIdentifier)?.conforms(to: .text) == true
    }
    
    private static func string(from itemProvider: NSItemProvider, type: String) async -> String? {
        if let data = await dataRepresentation(from: itemProvider, type: type),
           let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) {
            return string
        }
        guard let item = try? await itemProvider.loadItem(forTypeIdentifier: type) else {
            return nil
        }
        if let string = item as? String {
            return string
        }
        if let url = item as? URL, let data = await data(from: url) {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode)
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode)
    }
    
    @concurrent private static func data(from url: URL) async -> Data? {
        try? Data(contentsOf: url)
    }
    
    private static func data(from itemProvider: NSItemProvider, type: String) async -> Data? {
        if let data = await dataRepresentation(from: itemProvider, type: type) {
            return data
        }
        guard let item = try? await itemProvider.loadItem(forTypeIdentifier: type) else {
            return nil
        }
        if let data = item as? Data {
            return data
        }
        guard let url = item as? URL else {
            return nil
        }
        return await data(from: url)
    }
    
    @concurrent private static func plainText(fromRTF data: Data) async -> String? {
        try? NSAttributedString(data: data,
                                options: [.documentType: NSAttributedString.DocumentType.rtf],
                                documentAttributes: nil).string
    }
    
    private static func dataRepresentation(from itemProvider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            itemProvider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
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
    
    private static func utf8HTMLDocument(for html: String) -> String {
        if html.range(of: "<meta[^>]+charset", options: [.regularExpression, .caseInsensitive]) != nil {
            return html
        }
        
        if let headRange = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var document = html
            document.insert(contentsOf: #"<meta charset="utf-8">"#, at: headRange.upperBound)
            return document
        }
        
        return #"<!doctype html><html><head><meta charset="utf-8"></head><body>\#(html)</body></html>"#
    }
    
    private static func htmlBodyFragment(from html: String) -> String? {
        guard let openingBody = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]),
              let closingBody = html.range(of: "</body>", options: [.caseInsensitive], range: openingBody.upperBound..<html.endIndex) else {
            return nil
        }
        return String(html[openingBody.upperBound..<closingBody.lowerBound])
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
