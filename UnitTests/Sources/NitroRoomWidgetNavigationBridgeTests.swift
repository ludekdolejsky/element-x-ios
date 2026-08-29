//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroRoomWidgetNavigationBridgeTests {
    @Test
    func handlesMatrixNavigationRequest() throws {
        let message = #"{"api":"fromWidget","widgetId":"cockpit","requestId":"request","action":"org.matrix.msc2931.navigate","data":{"uri":"https://matrix.to/#/!room:example.org/$event:example.org"}}"#
        let expectedURL = try #require(URL(string: "https://matrix.to/#/!room:example.org/$event:example.org"))
        let request = try #require(NitroRoomWidgetNavigationBridge.navigationRequest(from: message))
        let response = try object(from: request.response)
        let responseBody = try #require(response["response"] as? [String: Any])
        
        #expect(request.url == expectedURL)
        #expect(response["requestId"] as? String == "request")
        #expect(responseBody.isEmpty)
    }
    
    @Test(arguments: [
        "https://example.org/#/!room:example.org",
        "http://matrix.to/#/!room:example.org",
        "https://matrix.to/#/not-a-matrix-entity",
        "https://matrix.to/#/@user:example.org"
    ])
    func rejectsInvalidNavigationTargets(uri: String) {
        let message = #"{"api":"fromWidget","widgetId":"cockpit","requestId":"request","action":"org.matrix.msc2931.navigate","data":{"uri":"\#(uri)"}}"#
        #expect(NitroRoomWidgetNavigationBridge.navigationRequest(from: message) == nil)
    }
    
    @Test
    func detectsRequestedNavigationCapability() {
        let message = #"{"api":"toWidget","widgetId":"cockpit","requestId":"request","action":"capabilities","data":{},"response":{"capabilities":["org.matrix.msc2931.navigate"]}}"#
        #expect(NitroRoomWidgetNavigationBridge.requestsNavigationCapability(message))
    }
    
    @Test
    func advertisesNavigationAPIVersion() throws {
        let message = #"{"api":"fromWidget","widgetId":"cockpit","requestId":"request","action":"supported_api_versions","data":{},"response":{"supported_versions":["0.0.1"]}}"#
        let updated = NitroRoomWidgetNavigationBridge.addingNavigationSupport(to: message, capabilityRequested: false)
        let response = try #require(try object(from: updated)["response"] as? [String: Any])
        let versions = try #require(response["supported_versions"] as? [String])
        
        #expect(versions == ["0.0.1", "org.matrix.msc2931"])
    }
    
    @Test
    func approvesRequestedNavigationCapability() throws {
        let message = #"{"api":"toWidget","widgetId":"cockpit","requestId":"request","action":"notify_capabilities","data":{"requested":[],"approved":[]}}"#
        let updated = NitroRoomWidgetNavigationBridge.addingNavigationSupport(to: message, capabilityRequested: true)
        let data = try #require(try object(from: updated)["data"] as? [String: Any])
        
        #expect(data["requested"] as? [String] == ["org.matrix.msc2931.navigate"])
        #expect(data["approved"] as? [String] == ["org.matrix.msc2931.navigate"])
    }
    
    private func object(from message: String) throws -> [String: Any] {
        let data = try #require(message.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
