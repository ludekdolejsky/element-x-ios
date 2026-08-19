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

        #expect(representations == [
            UTType.utf8PlainText.identifier: "Hello",
            UTType.html.identifier: html,
            NitroMessageCopyFormatter.formattedHTMLPasteboardType: html
        ])
    }

    @Test
    func providesSourceTextOnlyForExplicitFormats() {
        let html = "<strong>Hello</strong>"
        let item = textItem(body: "Hello", html: html)

        #expect(NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .markdown) == [
            UTType.utf8PlainText.identifier: "__Hello__",
            NitroMessageCopyFormatter.markdownPasteboardType: "__Hello__"
        ])
        #expect(NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .html) == [
            UTType.utf8PlainText.identifier: html
        ])
    }

    @Test
    func omitsHTMLRepresentationForPlainMessages() {
        let item = textItem(body: "2 < 3", html: nil)

        #expect(NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .text) == [
            UTType.utf8PlainText.identifier: "2 < 3"
        ])
    }

    @Test
    func readsRichPasteContent() {
        let item = textItem(body: "Hello", html: "<strong>Hello</strong>")
        let representations = NitroMessageCopyFormatter.pasteboardRepresentations(for: item, format: .text)
        UIPasteboard.general.setItems([representations.mapValues { $0 as Any }])
        defer { UIPasteboard.general.items = [] }

        #expect(NitroMessageCopyFormatter.richPasteContent(from: .general) == .html("<strong>Hello</strong>", plainText: "Hello"))
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
