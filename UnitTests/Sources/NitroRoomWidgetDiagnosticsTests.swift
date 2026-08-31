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
        let bridgeState = NitroRoomWidgetBridgeState(documentSequence: 2,
                                                     widgetMessagesReceived: 1,
                                                     driverScriptsStarted: 0,
                                                     driverScriptsCompleted: 0)
        
        diagnostics.handleJavaScriptMessage(#"{"phase":"widget_api_timeout","attempt":1,"elapsed_ms":20001}"#,
                                            bridgeState: bridgeState)
        diagnostics.handleJavaScriptMessage(#"{"phase":"widget_api_timeout","attempt":2,"elapsed_ms":45002}"#)
        diagnostics.handleJavaScriptMessage(#"{"phase":"widget_api_ready","attempt":3,"elapsed_ms":50123}"#)
        
        #expect(reports.map(\.kind) == [.failure, .breadcrumb, .recovery])
        #expect(reports.map(\.attempt) == [1, 2, 3])
        #expect(reports[0].origin == "https://widgets.example.org")
        #expect(!reports[0].origin.contains("secret"))
        #expect(reports[0].bridgeState == bridgeState)
        #expect(reports[0].bridgeState?.stage == "no_driver_reply")
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
    
    @Test
    func reportsDiagnosticBridgeReadiness() throws {
        var reports = [NitroRoomWidgetDiagnosticReport]()
        let diagnostics = try NitroRoomWidgetDiagnostics(widgetID: "cockpit",
                                                         url: #require(URL(string: "https://widgets.example.org/open")),
                                                         reporter: { reports.append($0) })
        let bridgeState = NitroRoomWidgetBridgeState(documentSequence: 3,
                                                     widgetMessagesReceived: 0,
                                                     driverScriptsStarted: 0,
                                                     driverScriptsCompleted: 0)
        
        let phase = diagnostics.handleJavaScriptMessage(#"{"phase":"diagnostic_bridge_ready","elapsed_ms":0}"#,
                                                        bridgeState: bridgeState)
        
        #expect(phase == "diagnostic_bridge_ready")
        #expect(reports.map(\.kind) == [.readiness])
        #expect(reports.map(\.phase) == ["diagnostic_bridge_ready"])
        #expect(reports[0].bridgeState == bridgeState)
    }
    
    @Test
    func nativeWatchdogReportsOnlyWhenJavaScriptDidNotReportTheFailure() throws {
        var reports = [NitroRoomWidgetDiagnosticReport]()
        let diagnostics = try NitroRoomWidgetDiagnostics(widgetID: "cockpit",
                                                         url: #require(URL(string: "https://widgets.example.org/open")),
                                                         reporter: { reports.append($0) })
        
        let bridgeState = NitroRoomWidgetBridgeState(documentSequence: 1,
                                                     widgetMessagesReceived: 1,
                                                     driverScriptsStarted: 1,
                                                     driverScriptsCompleted: 1)
        diagnostics.recordNativeWidgetAPITimeout(bridgeState: bridgeState)
        diagnostics.recordNativeWidgetAPITimeout()
        
        #expect(reports.map(\.phase) == ["native_widget_api_timeout"])
        #expect(reports[0].bridgeState?.stage == "driver_reply_posted_no_ready")
        
        reports.removeAll()
        let javaScriptDiagnostics = try NitroRoomWidgetDiagnostics(widgetID: "cockpit",
                                                                   url: #require(URL(string: "https://widgets.example.org/open")),
                                                                   reporter: { reports.append($0) })
        javaScriptDiagnostics.handleJavaScriptMessage(#"{"phase":"widget_api_timeout","attempt":1}"#)
        javaScriptDiagnostics.recordNativeWidgetAPITimeout()
        
        #expect(reports.map(\.phase) == ["widget_api_timeout"])
    }
}
