//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroRoomWidgetDiagnosticsTests {
    @Test
    func reportsTheFirstWidgetAPITimeoutAndSubsequentRecovery() throws {
        var reports = [NitroRoomWidgetDiagnosticReport]()
        let diagnostics = try NitroRoomWidgetDiagnostics(widgetID: "cockpit",
                                                         url: #require(URL(string: "https://widgets.example.org/open?token=secret")),
                                                         reporter: { reports.append($0) })
        
        diagnostics.handleJavaScriptMessage(#"{"phase":"widget_api_timeout","attempt":1,"elapsed_ms":20001}"#)
        diagnostics.handleJavaScriptMessage(#"{"phase":"widget_api_timeout","attempt":2,"elapsed_ms":45002}"#)
        diagnostics.handleJavaScriptMessage(#"{"phase":"widget_api_ready","attempt":3,"elapsed_ms":50123}"#)
        
        #expect(reports.map(\.kind) == [.failure, .breadcrumb, .recovery])
        #expect(reports.map(\.attempt) == [1, 2, 3])
        #expect(reports[0].origin == "https://widgets.example.org")
        #expect(!reports[0].origin.contains("secret"))
        #expect(reports[2].elapsedMilliseconds == 50123)
    }
    
    @Test
    func reportsEachNativeFailurePhaseOnlyOnce() throws {
        var reports = [NitroRoomWidgetDiagnosticReport]()
        let diagnostics = try NitroRoomWidgetDiagnostics(widgetID: "cockpit",
                                                         url: #require(URL(string: "https://widgets.example.org/open")),
                                                         reporter: { reports.append($0) })
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        
        diagnostics.recordNavigationFailure(phase: "navigation_failed", error: error)
        diagnostics.recordNavigationFailure(phase: "navigation_failed", error: error)
        
        #expect(reports.count == 1)
        #expect(reports[0].errorDomain == NSURLErrorDomain)
        #expect(reports[0].errorCode == NSURLErrorTimedOut)
    }
}
