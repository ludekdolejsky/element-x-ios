//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroRoomWidgetParserTests {
    @Test
    func parsesTrustedWidgetsFromBothStateEventTypes() {
        let widgets = NitroRoomWidgetParser.parse([
            event(stateKey: "cockpit", type: "com.nitrovery.c2m.cockpit", url: "https://pub-artifacts.nitrovery.com/cockpit", name: "Cockpit"),
            event(stateKey: "history", type: "com.nitrovery.c2m.history", url: "https://artifacts.nitrovery.com/history", name: "Thinking history")
        ])
        
        #expect(widgets.map(\.name) == ["Cockpit", "Thinking history"])
        #expect(widgets.map(\.id) == ["cockpit", "history"])
    }
    
    @Test
    func rejectsUntrustedTypesHostsAndSchemes() {
        let widgets = NitroRoomWidgetParser.parse([
            event(stateKey: "wrong-type", type: "m.custom", url: "https://pub-artifacts.nitrovery.com/widget", name: "Wrong type"),
            event(stateKey: "wrong-host", type: "com.nitrovery.c2m.widget", url: "https://example.org/widget", name: "Wrong host"),
            event(stateKey: "http", type: "com.nitrovery.c2m.widget", url: "http://pub-artifacts.nitrovery.com/widget", name: "HTTP")
        ])
        
        #expect(widgets.isEmpty)
    }
    
    @Test
    func newerStateEventReplacesLegacyEventWithSameWidgetID() throws {
        let widgets = NitroRoomWidgetParser.parse([
            event(stateKey: "widget", type: "com.nitrovery.c2m.cockpit", url: "https://pub-artifacts.nitrovery.com/old", name: "Old"),
            event(stateKey: "widget", type: "com.nitrovery.c2m.cockpit", url: "https://pub-artifacts.nitrovery.com/new", name: "New")
        ])
        
        let widget = try #require(widgets.first)
        #expect(widgets.count == 1)
        #expect(widget.name == "New")
        #expect(widget.url.path == "/new")
    }
    
    @Test
    func originRequiresHTTPSAndMatchesSchemeHostAndPort() throws {
        let widgetURL = try #require(URL(string: "https://artifacts.nitrovery.com/widget"))
        let sameOriginURL = try #require(URL(string: "https://artifacts.nitrovery.com/other"))
        let differentPortURL = try #require(URL(string: "https://artifacts.nitrovery.com:8443/other"))
        let insecureURL = try #require(URL(string: "http://artifacts.nitrovery.com/widget"))
        let origin = try #require(NitroRoomWidgetOrigin(url: widgetURL))
        
        #expect(origin.serialized == "https://artifacts.nitrovery.com")
        #expect(origin.matches(sameOriginURL))
        #expect(!origin.matches(differentPortURL))
        #expect(origin.matches(scheme: "https", host: "artifacts.nitrovery.com", port: 0))
        #expect(origin.matches(scheme: "https", host: "artifacts.nitrovery.com", port: 443))
        #expect(!origin.matches(scheme: "https", host: "artifacts.nitrovery.com", port: 8443))
        #expect(NitroRoomWidgetOrigin(url: insecureURL) == nil)
    }
    
    @Test
    func widgetLanguageTagUsesBCP47AndPreservesScripts() {
        #expect(NitroRoomWidgetLocale.languageTag(for: Locale(identifier: "cs_CZ")) == "cs-CZ")
        #expect(NitroRoomWidgetLocale.languageTag(for: Locale(identifier: "zh_Hant")) == "zh-Hant")
        #expect(NitroRoomWidgetLocale.languageTag(for: Locale(identifier: "sr_Latn_RS")) == "sr-Latn-RS")
    }
    
    private func event(stateKey: String, type: String, url: String, name: String) -> String {
        """
        {
          "state_key": "\(stateKey)",
          "content": {
            "id": "\(stateKey)",
            "name": "\(name)",
            "type": "\(type)",
            "url": "\(url)",
            "waitForIframeLoad": false
          }
        }
        """
    }
}
