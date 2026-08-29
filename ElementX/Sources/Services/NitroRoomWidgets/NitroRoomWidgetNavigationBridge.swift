//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

struct NitroRoomWidgetNavigationRequest: Equatable {
    let url: URL
    let response: String
}

enum NitroRoomWidgetNavigationBridge {
    static let capability = "org.matrix.msc2931.navigate"
    static let apiVersion = "org.matrix.msc2931"
    private static let action = "org.matrix.msc2931.navigate"
    private static let capabilitiesAction = "capabilities"
    private static let notifyCapabilitiesAction = "notify_capabilities"
    private static let supportedAPIVersionsAction = "supported_api_versions"
    
    static func navigationRequest(from message: String) -> NitroRoomWidgetNavigationRequest? {
        guard var object = object(from: message),
              object["api"] as? String == "fromWidget",
              object["action"] as? String == action,
              object["response"] == nil,
              let widgetID = object["widgetId"] as? String, !widgetID.isEmpty,
              let requestID = object["requestId"] as? String, !requestID.isEmpty,
              let data = object["data"] as? [String: Any],
              let uri = data["uri"] as? String,
              let url = URL(string: uri),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "matrix.to",
              let entity = parseMatrixEntityFrom(uri: uri) else {
            return nil
        }
        
        switch entity.id {
        case .room, .roomAlias, .eventOnRoomId, .eventOnRoomAlias:
            object["response"] = [String: Any]()
            guard let response = string(from: object) else { return nil }
            return .init(url: url, response: response)
        case .user:
            return nil
        }
    }
    
    static func requestsNavigationCapability(_ message: String) -> Bool {
        guard let object = object(from: message),
              object["api"] as? String == "toWidget",
              object["action"] as? String == capabilitiesAction,
              let response = object["response"] as? [String: Any],
              let capabilities = response["capabilities"] as? [String] else {
            return false
        }
        return capabilities.contains(capability)
    }
    
    static func addingNavigationSupport(to message: String, capabilityRequested: Bool) -> String {
        guard var object = object(from: message), let action = object["action"] as? String else { return message }
        
        let wasUpdated: Bool
        switch action {
        case supportedAPIVersionsAction:
            wasUpdated = append(apiVersion, to: "supported_versions", in: "response", of: &object)
        case notifyCapabilitiesAction where capabilityRequested:
            let requestedWasUpdated = append(capability, to: "requested", in: "data", of: &object)
            let approvedWasUpdated = append(capability, to: "approved", in: "data", of: &object)
            wasUpdated = requestedWasUpdated || approvedWasUpdated
        default:
            wasUpdated = false
        }
        
        guard wasUpdated else { return message }
        return string(from: object) ?? message
    }
    
    private static func append(_ value: String,
                               to arrayKey: String,
                               in containerKey: String,
                               of object: inout [String: Any]) -> Bool {
        guard var container = object[containerKey] as? [String: Any],
              var values = container[arrayKey] as? [String],
              !values.contains(value) else {
            return false
        }
        values.append(value)
        container[arrayKey] = values
        object[containerKey] = container
        return true
    }
    
    private static func object(from message: String) -> [String: Any]? {
        guard let data = message.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    
    private static func string(from object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
