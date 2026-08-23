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
    func providesSourceTextOnlyForExplicitFormats() {
        let html = "<strong>Hello</strong>"
        let item = textItem(body: "Hello", html: html)

        let markdownRepresentations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .markdown)
        #expect(markdownRepresentations.count == 1)
        #expect(markdownRepresentations[UTType.utf8PlainText.identifier] as? String == "__Hello__")

        let htmlRepresentations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .html)
        #expect(htmlRepresentations.count == 1)
        #expect(htmlRepresentations[UTType.utf8PlainText.identifier] as? String == html)
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
    func readsRichPasteContent() {
        let item = textItem(body: "Hello", html: "<strong>Hello</strong>")
        let representations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .text)
        UIPasteboard.general.setItems([representations])
        defer { UIPasteboard.general.items = [] }

        #expect(NitroMessageCopyFormatter.supportsRichPaste(UIPasteboard.general.itemProviders[0]))
        #expect(NitroMessageCopyFormatter.richPasteContent(from: .general) == .html("<strong>Hello</strong>", plainText: "Hello"))
    }

    @Test
    func readsStandardMarkdownPasteContent() {
        UIPasteboard.general.setItems([[
            NitroMessageCopyFormatter.markdownTypeIdentifier: "**Hello**"
        ]])
        defer { UIPasteboard.general.items = [] }

        #expect(NitroMessageCopyFormatter.richPasteContent(from: .general) == .markdown("**Hello**"))
    }

    @Test
    func derivesPlainTextWhenPastedHTMLHasNoPlainRepresentation() {
        UIPasteboard.general.setItems([[
            UTType.html.identifier: "<strong>Hello</strong>"
        ]])
        defer { UIPasteboard.general.items = [] }

        #expect(NitroMessageCopyFormatter.richPasteContent(from: .general) == .html("<strong>Hello</strong>", plainText: "Hello"))
    }

    @Test
    func supportsStandardRichTextProviders() {
        let htmlProvider = NSItemProvider(item: "<strong>Hello</strong>" as NSString,
                                          typeIdentifier: UTType.html.identifier)
        let markdownProvider = NSItemProvider(item: "**Hello**" as NSString,
                                              typeIdentifier: NitroMessageCopyFormatter.markdownTypeIdentifier)

        #expect(NitroMessageCopyFormatter.supportsRichPaste(htmlProvider))
        #expect(NitroMessageCopyFormatter.supportsRichPaste(markdownProvider))
    }

    @Test
    func prefersRichTextFromMixedProvider() {
        UIPasteboard.general.setItems([[
            UTType.pdf.identifier: Data(),
            UTType.html.identifier: "<strong>Hello</strong>"
        ]])
        defer { UIPasteboard.general.items = [] }

        let itemProvider = UIPasteboard.general.itemProviders[0]
        #expect(itemProvider.preferredContentType?.type == .pdf)
        #expect(NitroMessageCopyFormatter.supportsRichPaste(itemProvider))
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
}
