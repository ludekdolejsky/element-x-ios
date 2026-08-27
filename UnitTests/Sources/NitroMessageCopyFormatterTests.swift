//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers

struct NitroMessageCopyFormatterTests {
    @Test
    func convertsFormattedHTMLToMarkdown() {
        let item = textItem(body: "Intro\n\none\ntwo",
                            html: "<p>Intro</p><ul><li>one</li><li>two</li></ul>")
        #expect(NitroMessageCopyFormatter.markdown(for: item) == "Intro\n\n- one\n- two")
    }
    
    @Test
    func copiesOriginalHTML() {
        let html = "<strong>Hello</strong>"
        let item = textItem(body: "Hello", html: html)
        #expect(NitroMessageCopyFormatter.html(for: item) == html)
    }
    
    @Test
    func providesRichAndPlainRepresentationsForCopy() {
        let html = "<strong>Hello</strong>"
        let item = textItem(body: "Hello", html: html)
        let representations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .text)
        
        #expect(representations[UTType.utf8PlainText.identifier] as? String == "Hello")
        #expect(representations[UTType.html.identifier] as? String == html)
        #expect(representations[NitroMessageCopyFormatter.markdownTypeIdentifier] as? String == "__Hello__")
        #expect(!(representations[UTType.rtf.identifier] as? Data ?? Data()).isEmpty)
        #expect(Set(representations.keys) == [
            UTType.utf8PlainText.identifier,
            UTType.html.identifier,
            NitroMessageCopyFormatter.markdownTypeIdentifier,
            UTType.rtf.identifier
        ])
    }
    
    @Test
    func preservesCustomEmojiAcrossClipboardRepresentations() throws {
        let html = #"Hello <img data-mx-emoticon src="mxc://example.org/meatspin" alt="Meatspin" title="meatspin" height="32" />"#
        let item = textItem(body: "Hello :meatspin:", html: html)
        let representations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .text)
        
        #expect(representations[UTType.utf8PlainText.identifier] as? String == "Hello :meatspin:")
        #expect(representations[UTType.html.identifier] as? String == html)
        #expect(representations[NitroMessageCopyFormatter.markdownTypeIdentifier] as? String == "Hello :meatspin:")
        let rtf = try #require(representations[UTType.rtf.identifier] as? Data)
        let attributedString = try NSAttributedString(data: rtf,
                                                      options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                      documentAttributes: nil)
        #expect(attributedString.string == "Hello :meatspin:")
    }
    
    @Test
    func providesSourceAndTypedRepresentationsForExplicitFormats() {
        let html = "<strong>Hello</strong>"
        let item = textItem(body: "Hello", html: html)
        
        let markdownRepresentations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .markdown)
        #expect(markdownRepresentations.count == 2)
        #expect(markdownRepresentations[UTType.utf8PlainText.identifier] as? String == "__Hello__")
        #expect(markdownRepresentations[NitroMessageCopyFormatter.markdownTypeIdentifier] as? String == "__Hello__")
        
        let htmlRepresentations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .html)
        #expect(htmlRepresentations.count == 3)
        #expect(htmlRepresentations[UTType.utf8PlainText.identifier] as? String == html)
        #expect((htmlRepresentations[UTType.html.identifier] as? String)?.contains(#"<meta charset="utf-8">"#) == true)
        #expect((htmlRepresentations[UTType.html.identifier] as? String)?.contains(html) == true)
        #expect(!(htmlRepresentations[UTType.rtf.identifier] as? Data ?? Data()).isEmpty)
    }
    
    @Test
    func explicitHTMLPreservesUnicodeInRTF() throws {
        let text = "Příliš žluťoučký kůň — 日本語"
        let item = textItem(body: text, html: "<strong>\(text)</strong>")
        let representations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .html)
        let rtf = try #require(representations[UTType.rtf.identifier] as? Data)
        let attributedString = try NSAttributedString(data: rtf,
                                                      options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                      documentAttributes: nil)
        
        #expect(attributedString.string == text)
    }
    
    @Test
    func providesStandardRepresentationsForPlainMessages() {
        let item = textItem(body: "2 < 3", html: nil)
        let representations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .text)
        
        #expect(representations[UTType.utf8PlainText.identifier] as? String == "2 < 3")
        #expect(representations[UTType.html.identifier] as? String == "<p>2 &lt; 3</p>")
        #expect(representations[NitroMessageCopyFormatter.markdownTypeIdentifier] as? String == "2 < 3")
        #expect(!(representations[UTType.rtf.identifier] as? Data ?? Data()).isEmpty)
    }
    
    @Test
    func readsRichPasteContent() async {
        let item = textItem(body: "Hello", html: "<strong>Hello</strong>")
        let representations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .text)
        let itemProvider = itemProvider(representations: representations)
        #expect(NitroMessageCopyFormatter.supportsTextPaste(itemProvider))
        #expect(await NitroMessageCopyFormatter.richPasteContent(from: itemProvider) == .html("<strong>Hello</strong>", plainText: "Hello"))
    }
    
    @Test
    func readsStandardMarkdownPasteContent() async {
        let item = textItem(body: "Hello", html: "<strong>Hello</strong>")
        let representations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .markdown)
        #expect(await NitroMessageCopyFormatter.richPasteContent(from: itemProvider(representations: representations)) == .markdown("__Hello__"))
    }
    
    @Test
    func readsExplicitHTMLPasteContent() async {
        let item = textItem(body: "Hello", html: "<strong>Hello</strong>")
        let representations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .html)
        let content = await NitroMessageCopyFormatter.richPasteContent(from: itemProvider(representations: representations))
        guard case let .html(html, plainText) = content else {
            Issue.record("Expected HTML paste content")
            return
        }
        #expect(html == "<strong>Hello</strong>")
        #expect(plainText == "Hello")
    }
    
    @Test
    func derivesPlainTextWhenPastedHTMLHasNoPlainRepresentation() async {
        let itemProvider = itemProvider(representations: [
            UTType.html.identifier: "<strong>Hello</strong>"
        ])
        
        #expect(await NitroMessageCopyFormatter.richPasteContent(from: itemProvider) == .html("<strong>Hello</strong>", plainText: "Hello"))
    }
    
    @Test
    func readsPlainTextFromNotesProvider() async throws {
        let rtf = try NSAttributedString(string: "Hello from Notes").data(from: NSRange(location: 0, length: 16),
                                                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let itemProvider = itemProvider(representations: [
            "com.apple.webarchive": Data("webarchive".utf8),
            UTType.rtf.identifier: rtf,
            UTType.utf8PlainText.identifier: "Hello from Notes"
        ])
        
        #expect(NitroMessageCopyFormatter.supportsTextPaste(itemProvider))
        #expect(await NitroMessageCopyFormatter.richPasteContent(from: itemProvider) == .plainText("Hello from Notes"))
    }
    
    @Test
    func fallsBackToPlainTextFromRTF() async throws {
        let text = "Only RTF"
        let rtf = try NSAttributedString(string: text).data(from: NSRange(location: 0, length: text.utf16.count),
                                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let itemProvider = itemProvider(representations: [UTType.rtf.identifier: rtf])
        
        #expect(NitroMessageCopyFormatter.supportsTextPaste(itemProvider))
        #expect(await NitroMessageCopyFormatter.richPasteContent(from: itemProvider) == .plainText(text))
    }
    
    @Test
    func readsGenericTextProvider() async {
        let provider = itemProvider(representations: [
            UTType.text.identifier: "Selected text from Mail"
        ])
        
        #expect(NitroMessageCopyFormatter.supportsTextPaste(provider))
        #expect(await NitroMessageCopyFormatter.richPasteContent(from: provider) == .plainText("Selected text from Mail"))
    }
    
    @Test
    func clipboardDiagnosticsExcludeContent() async {
        let secret = "private email content"
        let provider = itemProvider(representations: [
            UTType.text.identifier: secret,
            UTType.pdf.identifier: Data("pdf".utf8)
        ])
        
        let report = await NitroClipboardDiagnostics.report(itemProviders: [provider],
                                                            generatedAt: Date(timeIntervalSince1970: 0),
                                                            systemName: "iOS",
                                                            systemVersion: "27.0",
                                                            appVersion: "1.0",
                                                            buildNumber: "1")
        
        #expect(report.contains("public.text"))
        #expect(report.contains(UTType.pdf.identifier))
        #expect(report.contains("Selected format: Generic text"))
        #expect(report.contains("Content included: no"))
        #expect(!report.contains(secret))
    }
    
    @Test
    func supportsStandardRichTextProviders() {
        let htmlProvider = NSItemProvider(item: "<strong>Hello</strong>" as NSString,
                                          typeIdentifier: UTType.html.identifier)
        let markdownProvider = NSItemProvider(item: "**Hello**" as NSString,
                                              typeIdentifier: NitroMessageCopyFormatter.markdownTypeIdentifier)
        
        #expect(NitroMessageCopyFormatter.supportsTextPaste(htmlProvider))
        #expect(NitroMessageCopyFormatter.supportsTextPaste(markdownProvider))
    }
    
    @Test
    func prefersRichTextFromMixedProvider() {
        let itemProvider = itemProvider(representations: [
            UTType.pdf.identifier: Data(),
            UTType.html.identifier: "<strong>Hello</strong>"
        ])
        #expect(itemProvider.preferredContentType?.type == .pdf)
        #expect(NitroMessageCopyFormatter.supportsTextPaste(itemProvider))
    }
    
    @Test
    func fallsBackToPlainBody() {
        let item = textItem(body: "Hello", html: nil)
        #expect(NitroMessageCopyFormatter.markdown(for: item) == "Hello")
        #expect(NitroMessageCopyFormatter.html(for: item) == "Hello")
    }
    
    @Test
    func preservesCodeBlockContents() {
        let item = textItem(body: "* literal bullet",
                            html: "<pre><code>* literal bullet</code></pre>")
        #expect(NitroMessageCopyFormatter.markdown(for: item) == "```\n* literal bullet\n```\n")
    }
    
    private func textItem(body: String, html: String?) -> TextRoomTimelineItem {
        TextRoomTimelineItem(id: .randomEvent,
                             timestamp: Date(),
                             isOutgoing: false,
                             isEditable: false,
                             canBeRepliedTo: true,
                             sender: .init(id: "@alice:example.org", displayName: "Alice"),
                             content: .init(body: body, formattedBodyHTMLString: html))
    }
    
    private func itemProvider(representations: [String: Any]) -> NSItemProvider {
        let provider = NSItemProvider()
        for (type, value) in representations {
            let data: Data? = switch value {
            case let data as Data: data
            case let string as String: string.data(using: .utf8)
            default: nil
            }
            provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
}
