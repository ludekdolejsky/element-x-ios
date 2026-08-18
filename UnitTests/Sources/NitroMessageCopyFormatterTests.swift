//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

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
