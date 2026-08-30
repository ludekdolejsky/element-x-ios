//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Sentry
import UIKit

struct NitroRoomWidgetDiagnosticReport: Equatable {
    enum Kind: Equatable {
        case failure
        case recovery
        case breadcrumb
    }
    
    let kind: Kind
    let phase: String
    let sessionID: String
    let widgetID: String
    let origin: String
    let attempt: Int?
    let elapsedMilliseconds: Int?
    let errorDomain: String?
    let errorCode: Int?
    let statusCode: Int?
    let applicationState: String
}

final class NitroRoomWidgetDiagnostics {
    private struct JavaScriptReport: Decodable {
        let phase: String
        let attempt: Int?
        let elapsedMilliseconds: Int?
        let statusCode: Int?
        
        enum CodingKeys: String, CodingKey {
            case phase
            case attempt
            case elapsedMilliseconds = "elapsed_ms"
            case statusCode = "status_code"
        }
    }
    
    private let sessionID = UUID().uuidString
    private let widgetID: String
    private let origin: String
    private let reporter: @MainActor (NitroRoomWidgetDiagnosticReport) -> Void
    private var reportedFailurePhases = Set<String>()
    private var hasReportedJavaScriptFailure = false
    private var hasReportedJavaScriptRecovery = false
    
    init(widgetID: String,
         url: URL,
         reporter: @escaping @MainActor (NitroRoomWidgetDiagnosticReport) -> Void = NitroRoomWidgetDiagnostics.reportToSentry) {
        self.widgetID = widgetID
        origin = NitroRoomWidgetOrigin(url: url)?.serialized ?? "unknown"
        self.reporter = reporter
    }
    
    func recordNavigationFailure(phase: String, error: any Error) {
        let error = error as NSError
        recordFailure(phase: phase, errorDomain: error.domain, errorCode: error.code)
    }
    
    func recordHTTPFailure(statusCode: Int?) {
        recordFailure(phase: "navigation_http", statusCode: statusCode)
    }
    
    func recordWebContentProcessTermination() {
        recordFailure(phase: "web_content_process_terminated")
    }
    
    func handleJavaScriptMessage(_ body: String) {
        guard let data = body.data(using: .utf8),
              let report = try? JSONDecoder().decode(JavaScriptReport.self, from: data) else {
            recordFailure(phase: "diagnostic_payload_invalid")
            return
        }
        
        switch report.phase {
        case "widget_api_ready", "authorization_ready":
            guard hasReportedJavaScriptFailure, !hasReportedJavaScriptRecovery else { return }
            hasReportedJavaScriptRecovery = true
            reporter(makeReport(kind: .recovery,
                                phase: report.phase,
                                attempt: report.attempt,
                                elapsedMilliseconds: report.elapsedMilliseconds))
        case "widget_api_timeout", "widget_api_library_missing", "authorization_failed":
            let isFirstFailure = !hasReportedJavaScriptFailure
            hasReportedJavaScriptFailure = true
            reporter(makeReport(kind: isFirstFailure ? .failure : .breadcrumb,
                                phase: report.phase,
                                attempt: report.attempt,
                                elapsedMilliseconds: report.elapsedMilliseconds,
                                statusCode: report.statusCode))
        default:
            reporter(makeReport(kind: .breadcrumb,
                                phase: report.phase,
                                attempt: report.attempt,
                                elapsedMilliseconds: report.elapsedMilliseconds,
                                statusCode: report.statusCode))
        }
    }
    
    private func recordFailure(phase: String,
                               errorDomain: String? = nil,
                               errorCode: Int? = nil,
                               statusCode: Int? = nil) {
        guard reportedFailurePhases.insert(phase).inserted else { return }
        reporter(makeReport(kind: .failure,
                            phase: phase,
                            errorDomain: errorDomain,
                            errorCode: errorCode,
                            statusCode: statusCode))
    }
    
    private func makeReport(kind: NitroRoomWidgetDiagnosticReport.Kind,
                            phase: String,
                            attempt: Int? = nil,
                            elapsedMilliseconds: Int? = nil,
                            errorDomain: String? = nil,
                            errorCode: Int? = nil,
                            statusCode: Int? = nil) -> NitroRoomWidgetDiagnosticReport {
        let applicationState = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        return .init(kind: kind,
                     phase: phase,
                     sessionID: sessionID,
                     widgetID: widgetID,
                     origin: origin,
                     attempt: attempt,
                     elapsedMilliseconds: elapsedMilliseconds,
                     errorDomain: errorDomain,
                     errorCode: errorCode,
                     statusCode: statusCode,
                     applicationState: applicationState)
    }
    
    private static func reportToSentry(_ report: NitroRoomWidgetDiagnosticReport) {
        let breadcrumb = Breadcrumb(level: report.kind == .failure ? .warning : .info, category: "nitro.room_widget")
        breadcrumb.message = report.phase
        for (key, value) in sentryData(for: report) {
            breadcrumb.setData(value: value, key: key)
        }
        SentrySDK.addBreadcrumb(breadcrumb)
        
        guard report.kind != .breadcrumb else { return }
        let event = Event(level: report.kind == .failure ? .warning : .info)
        event.message = SentryMessage(formatted: report.kind == .failure ? "Nitro room widget failure" : "Nitro room widget recovered")
        event.tags = [
            "nitro.widget.phase": report.phase,
            "nitro.widget.id": report.widgetID,
            "nitro.widget.origin": report.origin,
            "nitro.widget.app_state": report.applicationState
        ]
        event.extra = sentryData(for: report)
        SentrySDK.capture(event: event)
    }
    
    private static func sentryData(for report: NitroRoomWidgetDiagnosticReport) -> [String: Any] {
        var data: [String: Any] = ["session_id": report.sessionID,
                                   "widget_id": report.widgetID,
                                   "origin": report.origin,
                                   "application_state": report.applicationState]
        data["attempt"] = report.attempt
        data["elapsed_ms"] = report.elapsedMilliseconds
        data["error_domain"] = report.errorDomain
        data["error_code"] = report.errorCode
        data["status_code"] = report.statusCode
        return data
    }
}
