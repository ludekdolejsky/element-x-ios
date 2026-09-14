//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import SwiftSoup
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
            let content: String?
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

    private struct HTMLPasteResolution {
        let preferredContent: ResolvedRichPasteContent?
        let textFallback: ResolvedRichPasteContent?
    }

    static func pasteboardRepresentations(for item: EventBasedMessageTimelineItemProtocol, format: Format) -> [String: Any] {
        switch format {
        case .text:
            let content = renderedContent(for: item)
            var representations: [String: Any] = [
                UTType.utf8PlainText.identifier: content.plainText,
                UTType.html.identifier: utf8HTMLDocument(for: content.html),
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
            let data = conformsToText ? await dataRepresentation(from: itemProvider, type: typeIdentifier) : nil
            let content: String? = if typeIdentifier == UTType.rtf.identifier, let data {
                await plainText(fromRTF: data)
            } else if let data {
                String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode)
            } else if conformsToText {
                await string(from: itemProvider, type: typeIdentifier)
            } else {
                nil
            }
            representations.append(.init(typeIdentifier: typeIdentifier,
                                         conformsToText: conformsToText,
                                         byteCount: data?.count ?? content?.utf8.count,
                                         content: content))
        }

        return .init(supportsTextPaste: supportsTextPaste(itemProvider),
                     selectedTypeIdentifier: resolution?.typeIdentifier,
                     selectedFormat: resolution?.format,
                     representations: representations)
    }

    private static func resolvedRichPasteContent(from itemProvider: NSItemProvider) async -> ResolvedRichPasteContent? {
        let htmlResolution = await htmlPasteResolution(from: itemProvider)
        if let preferredContent = htmlResolution?.preferredContent {
            return preferredContent
        }

        if itemProvider.hasItemConformingToTypeIdentifier(markdownTypeIdentifier),
           let markdown = await nonEmptyText(string(from: itemProvider, type: markdownTypeIdentifier)) {
            return .init(content: .markdown(markdown),
                         typeIdentifier: markdownTypeIdentifier,
                         format: "Markdown")
        }

        for type in plainTextTypeIdentifiers where itemProvider.registeredTypeIdentifiers.contains(type) {
            if let plainText = await nonEmptyText(string(from: itemProvider, type: type)) {
                return .init(content: .plainText(plainText),
                             typeIdentifier: type,
                             format: "Plain text")
            }
        }

        if itemProvider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier),
           let data = await data(from: itemProvider, type: UTType.rtf.identifier),
           let plainText = await nonEmptyText(plainText(fromRTF: data)) {
            return .init(content: .plainText(plainText),
                         typeIdentifier: UTType.rtf.identifier,
                         format: "RTF")
        }

        let registeredTypes = itemProvider.registeredTypeIdentifiers.filter {
            !plainTextTypeIdentifiers.contains($0) &&
                $0 != UTType.html.identifier &&
                $0 != UTType.rtf.identifier &&
                isTextType($0)
        }
        for type in registeredTypes {
            if let plainText = await nonEmptyText(string(from: itemProvider, type: type)) {
                return .init(content: .plainText(plainText),
                             typeIdentifier: type,
                             format: "Generic text")
            }
        }

        if let textFallback = htmlResolution?.textFallback {
            return textFallback
        }

        if htmlResolution == nil,
           itemProvider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
           let plainText = await nonEmptyText(string(from: itemProvider, type: UTType.text.identifier)) {
            return .init(content: .plainText(plainText),
                         typeIdentifier: UTType.text.identifier,
                         format: "Conforming text fallback")
        }

        return nil
    }

    private static func htmlPasteResolution(from itemProvider: NSItemProvider) async -> HTMLPasteResolution? {
        guard itemProvider.hasItemConformingToTypeIdentifier(UTType.html.identifier),
              let html = await string(from: itemProvider, type: UTType.html.identifier) else {
            return nil
        }
        let sourceHTML = htmlBodyFragment(from: html) ?? html
        let composerHTML = composerCompatibleHTML(from: sourceHTML)
        let normalizedDivs = composerHTML != sourceHTML
        let renderedContent = renderedContent(forHTML: composerHTML)
        let renderedPlainText = renderedContent.plainText
        let comparablePlainText = (try? SwiftSoup.parseBodyFragment(sourceHTML).text()) ?? renderedPlainText
        let providedPlainText = await string(from: itemProvider, type: UTType.utf8PlainText.identifier)
        let nonEmptyProvidedPlainText = nonEmptyText(providedPlainText)
        let providedPlainTextIsHTMLSource = nonEmptyProvidedPlainText == composerHTML || nonEmptyProvidedPlainText == html ||
            nonEmptyProvidedPlainText.map { utf8HTMLDocument(for: $0) == html } == true
        let usableProvidedPlainText = providedPlainTextIsHTMLSource ? nil : nonEmptyProvidedPlainText
        let derivedPlainText = nonEmptyText(renderedContent.attributedString.string) ?? nonEmptyText(comparablePlainText) ?? renderedPlainText
        let plainText = usableProvidedPlainText ?? derivedPlainText
        let renderedTextMatchesFallback = !normalizedDivs || providedPlainTextIsHTMLSource || nonEmptyProvidedPlainText == nil ||
            normalizedPlainText(comparablePlainText) == normalizedPlainText(nonEmptyProvidedPlainText ?? "")
        if renderedContent.isComplete,
           !renderedPlainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           renderedTextMatchesFallback {
            let content = ResolvedRichPasteContent(content: .html(composerHTML, plainText: plainText),
                                                   typeIdentifier: UTType.html.identifier,
                                                   format: "HTML")
            return .init(preferredContent: content, textFallback: nil)
        }
        if let usableProvidedPlainText {
            let content = ResolvedRichPasteContent(content: .plainText(usableProvidedPlainText),
                                                   typeIdentifier: UTType.utf8PlainText.identifier,
                                                   format: "Plain text fallback")
            return .init(preferredContent: nil, textFallback: content)
        }
        let textFallback = nonEmptyText(derivedPlainText).map {
            ResolvedRichPasteContent(content: .plainText($0),
                                     typeIdentifier: UTType.html.identifier,
                                     format: "HTML text fallback")
        }
        return .init(preferredContent: nil, textFallback: textFallback)
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

    static func composerCompatibleHTML(fromMarkdown markdown: String) -> String? {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var html = ""
        var markdownLines = [String]()
        var codeLines = [String]()
        var activeFence: (marker: Character, length: Int)?
        var foundCodeBlock = false

        func appendMarkdownLines() {
            guard !markdownLines.isEmpty else { return }
            let markdown = markdownLines.joined(separator: "\n")
            let viewModel = WysiwygComposerViewModel()
            viewModel.setMarkdownContent(markdown)
            html += viewModel.content.html.isEmpty && !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? htmlForPlainText(markdown)
                : viewModel.content.html
            markdownLines.removeAll(keepingCapacity: true)
        }

        for rawLine in lines.map(String.init) {
            if let fence = activeFence {
                if isClosingFence(rawLine, matching: fence) {
                    html += "<pre><code>\(escapedHTML(codeLines.joined(separator: "\n")))</code></pre>"
                    codeLines.removeAll(keepingCapacity: true)
                    activeFence = nil
                    foundCodeBlock = true
                } else {
                    codeLines.append(rawLine)
                }
            } else if let fence = openingFence(in: rawLine) {
                appendMarkdownLines()
                activeFence = fence
            } else {
                markdownLines.append(rawLine)
            }
        }

        guard activeFence == nil, foundCodeBlock else { return nil }
        appendMarkdownLines()
        return html
    }

    private struct RenderedContent {
        let plainText: String
        let html: String
        let markdown: String
        let attributedString: NSAttributedString
        let isComplete: Bool
    }

    private static func renderedContent(for item: EventBasedMessageTimelineItemProtocol) -> RenderedContent {
        guard let html = formattedBodyHTML(for: item) else {
            return .init(plainText: item.body,
                         html: htmlForPlainText(item.body),
                         markdown: item.body,
                         attributedString: .init(string: item.body),
                         isComplete: true)
        }
        return renderedContent(forHTML: html, fallbackBody: item.body)
    }

    private static func renderedContent(forHTML html: String, fallbackBody: String? = nil) -> RenderedContent {
        let wysiwygHTML = CustomEmojiMessageContent.restoringShortcodes(in: html, fallbackBody: fallbackBody)
        let viewModel = WysiwygComposerViewModel()
        viewModel.setHtmlContent(wysiwygHTML)
        let renderedAttributedString = viewModel.attributedContent.text
        let renderedPlainText = renderedAttributedString.string
        let hasRenderedText = !renderedPlainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sourcePlainText = (try? SwiftSoup.parseBodyFragment(wysiwygHTML).text()) ?? fallbackBody
        let renderedAllText = sourcePlainText.map {
            normalizedPlainText($0) == normalizedPlainText(renderedPlainText)
        } ?? hasRenderedText
        let hasCompleteRenderedText = hasRenderedText && renderedAllText
        let plainText = hasCompleteRenderedText
            ? renderedPlainText
            : fallbackBody ?? renderedPlainText
        let renderedMarkdown = desktopCompatibleMarkdown(viewModel.content.markdown)
        let markdown = if hasCompleteRenderedText,
                          !renderedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            renderedMarkdown
        } else if let fallbackMarkdown = markdownFallback(fromHTML: wysiwygHTML),
                  !fallbackMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fallbackMarkdown
        } else {
            fallbackBody ?? renderedMarkdown
        }
        let attributedString = if hasCompleteRenderedText {
            renderedAttributedString
        } else if let htmlAttributedString = attributedString(fromHTML: wysiwygHTML),
                  !htmlAttributedString.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            htmlAttributedString
        } else {
            NSAttributedString(string: plainText)
        }
        return .init(plainText: plainText,
                     html: html,
                     markdown: markdown,
                     attributedString: attributedString,
                     isComplete: hasCompleteRenderedText)
    }

    private static func htmlForPlainText(_ text: String) -> String {
        let escaped = escapedHTML(text)
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<p>\(escaped)</p>"
    }

    private static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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

    private static func composerCompatibleHTML(from html: String) -> String {
        guard let document = try? SwiftSoup.parseBodyFragment(html),
              let body = document.body(),
              let divs = try? body.select("div") else {
            return html
        }
        document.outputSettings().prettyPrint(pretty: false)

        do {
            for div in divs {
                if try div.html().range(of: #"^\s*<br\s*/?>\s*$"#,
                                        options: [.regularExpression, .caseInsensitive]) != nil {
                    div.empty()
                }
                let styles = try inlineStyles(from: div.attr("style"))
                try div.tagName("p")
                if isBold(styles["font-weight"]) {
                    try div.wrap("<strong></strong>")
                }
                if isItalic(styles["font-style"]) {
                    try div.wrap("<em></em>")
                }
                let textDecoration = styles["text-decoration-line"] ?? styles["text-decoration"]
                if textDecoration?.contains("underline") == true {
                    try div.wrap("<u></u>")
                }
                if textDecoration?.contains("line-through") == true {
                    try div.wrap("<del></del>")
                }
            }
            return try body.html()
        } catch {
            return html
        }
    }

    private static func inlineStyles(from style: String) -> [String: String] {
        style.split(separator: ";").reduce(into: [:]) { styles, declaration in
            let components = declaration.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            guard components.count == 2 else { return }
            styles[components[0]] = components[1]
        }
    }

    private static func isBold(_ fontWeight: String?) -> Bool {
        guard let fontWeight else { return false }
        if fontWeight.contains("bold") {
            return true
        }
        return Int(fontWeight.prefix { $0.isNumber }) ?? 0 >= 600
    }

    private static func isItalic(_ fontStyle: String?) -> Bool {
        guard let fontStyle else { return false }
        return fontStyle.contains("italic") || fontStyle.contains("oblique")
    }

    private static func normalizedPlainText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func nonEmptyText(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func rtfData(from attributedString: NSAttributedString) -> Data? {
        try? attributedString.data(from: NSRange(location: 0, length: attributedString.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private static func attributedString(fromHTML html: String) -> NSAttributedString? {
        guard let data = utf8HTMLDocument(for: html).data(using: .utf8) else { return nil }
        return try? NSAttributedString(data: data,
                                       options: [.documentType: NSAttributedString.DocumentType.html,
                                                 .characterEncoding: String.Encoding.utf8.rawValue],
                                       documentAttributes: nil)
    }

    private static func markdownFallback(fromHTML html: String) -> String? {
        guard let document = try? SwiftSoup.parseBodyFragment(html),
              let body = document.body(),
              let markdown = try? markdown(from: body, listDepth: 0) else {
            return nil
        }
        return markdown
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func markdown(from node: Node, listDepth: Int) throws -> String {
        if let textNode = node as? TextNode {
            let text = textNode.getWholeText().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return markdownEscapedText(text)
        }
        guard let element = node as? Element else { return "" }

        let content = try element.getChildNodes().map { try markdown(from: $0, listDepth: listDepth) }.joined()
        switch element.tagName().lowercased() {
        case "body":
            return content
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(element.tagName().dropFirst()) ?? 1
            return "\(String(repeating: "#", count: level)) \(content.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        case "p", "div":
            return "\(content.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        case "br":
            return "\n"
        case "strong", "b":
            return "__\(content)__"
        case "em", "i":
            return "_\(content)_"
        case "del", "s", "strike":
            return "~~\(content)~~"
        case "code" where element.parent()?.tagName().lowercased() != "pre":
            return markdownInlineCode(preformattedText(from: element))
        case "pre":
            let text = preformattedText(from: element)
            let fence = markdownBackticks(for: text, minimumLength: 3)
            return "\(fence)\n\(text)\n\(fence)\n\n"
        case "ul":
            return try markdownList(from: element, ordered: false, depth: listDepth)
        case "ol":
            return try markdownList(from: element, ordered: true, depth: listDepth)
        case "li":
            return content
        case "blockquote":
            let quoted = content.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            return "\(quoted)\n\n"
        case "table":
            return try markdownTable(from: element, listDepth: listDepth)
        case "a":
            let href = try element.attr("href")
            return href.isEmpty ? content : "[\(content)](\(markdownLinkDestination(href)))"
        case "img":
            let title = try element.attr("title")
            let alt = try element.attr("alt")
            return title.isEmpty ? alt : title
        default:
            return content
        }
    }

    private static func markdownList(from element: Element, ordered: Bool, depth: Int) throws -> String {
        var result = ""
        var itemNumber = 1
        for child in element.children() where child.tagName().lowercased() == "li" {
            var itemContent = ""
            var nestedLists = ""
            for node in child.getChildNodes() {
                if let nestedList = node as? Element,
                   ["ul", "ol"].contains(nestedList.tagName().lowercased()) {
                    nestedLists += try markdownList(from: nestedList,
                                                    ordered: nestedList.tagName().lowercased() == "ol",
                                                    depth: depth + 1)
                } else {
                    itemContent += try markdown(from: node, listDepth: depth)
                }
            }
            let marker = ordered ? "\(itemNumber)." : "-"
            result += "\(String(repeating: "  ", count: depth))\(marker) \(itemContent.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            result += nestedLists
            itemNumber += 1
        }
        return depth == 0 ? "\(result)\n" : result
    }

    private static func preformattedText(from node: Node) -> String {
        if let textNode = node as? TextNode {
            return textNode.getWholeText()
        }
        guard let element = node as? Element else { return "" }
        if element.tagName().lowercased() == "br" {
            return "\n"
        }
        return element.getChildNodes().map(preformattedText).joined()
    }

    private static func markdownInlineCode(_ source: String) -> String {
        let text = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
        let delimiter = markdownBackticks(for: text, minimumLength: 1)
        let needsPadding = text.contains("`") || text.hasPrefix(" ") || text.hasSuffix(" ")
        let padding = needsPadding ? " " : ""
        return "\(delimiter)\(padding)\(text)\(padding)\(delimiter)"
    }

    private static func markdownBackticks(for text: String, minimumLength: Int) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in text {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: max(minimumLength, longestRun + 1))
    }

    private static func markdownEscapedText(_ text: String) -> String {
        let escapableCharacters: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "~"]
        let escaped = text.reduce(into: "") { result, character in
            if escapableCharacters.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return escapingMarkdownBlockMarker(in: escaped)
    }

    private static func escapingMarkdownBlockMarker(in line: String) -> String {
        let indentation = line.prefix { $0.isWhitespace }
        let content = line.dropFirst(indentation.count)
        guard !content.isEmpty else { return line }

        let markerPatterns = [#"^(#{1,6}|>|[-+])\s"#, #"^\d+[.)]\s"#, #"^-{3,}\s*$"#]
        guard let match = markerPatterns.lazy.compactMap({ pattern in
            content.range(of: pattern, options: .regularExpression)
        }).first else {
            return line
        }
        let marker = content[match].firstIndex { $0 == "." || $0 == ")" } ?? content.startIndex
        var escapedContent = String(content)
        escapedContent.insert("\\", at: escapedContent.index(escapedContent.startIndex,
                                                             offsetBy: content.distance(from: content.startIndex, to: marker)))
        return "\(indentation)\(escapedContent)"
    }

    private static func markdownLinkDestination(_ destination: String) -> String {
        destination
            .replacingOccurrences(of: "\\", with: #"\\"#)
            .replacingOccurrences(of: "(", with: #"\("#)
            .replacingOccurrences(of: ")", with: #"\)"#)
    }

    private static func markdownTable(from table: Element, listDepth: Int) throws -> String {
        let rows = tableRows(in: table)
        guard !rows.isEmpty else { return "" }

        var renderedRows = try rows.map { row in
            try row.children()
                .filter { ["th", "td"].contains($0.tagName().lowercased()) }
                .map { try markdownTableCell(from: $0, listDepth: listDepth) }
        }
        let columnCount = renderedRows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return "" }
        renderedRows = renderedRows.map { $0 + Array(repeating: "", count: columnCount - $0.count) }

        let firstRowIsHeader = rows[0].children().contains { $0.tagName().lowercased() == "th" }
        let header = firstRowIsHeader ? renderedRows.removeFirst() : Array(repeating: "", count: columnCount)
        var lines = [markdownTableRow(header), markdownTableRow(Array(repeating: "---", count: columnCount))]
        lines.append(contentsOf: renderedRows.map(markdownTableRow))

        let caption = table.children().first { $0.tagName().lowercased() == "caption" }
        let renderedCaption = try caption.map { try markdown(from: $0, listDepth: listDepth) }
            .map { "_\($0.trimmingCharacters(in: .whitespacesAndNewlines))_\n\n" } ?? ""
        return "\(renderedCaption)\(lines.joined(separator: "\n"))\n\n"
    }

    private static func tableRows(in element: Element) -> [Element] {
        element.children().flatMap { child -> [Element] in
            switch child.tagName().lowercased() {
            case "tr":
                [child]
            case "thead", "tbody", "tfoot":
                tableRows(in: child)
            default:
                []
            }
        }
    }

    private static func markdownTableCell(from cell: Element, listDepth: Int) throws -> String {
        try markdown(from: cell, listDepth: listDepth)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "|", with: #"\|"#)
            .replacingOccurrences(of: #"\s*\n\s*"#, with: "<br>", options: .regularExpression)
    }

    private static func markdownTableRow(_ cells: [String]) -> String {
        "| \(cells.joined(separator: " | ")) |"
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
