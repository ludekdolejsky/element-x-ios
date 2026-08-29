//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

struct NitroRoomWidget: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let type: String
    let url: URL
    let waitForIframeLoad: Bool
}

enum NitroRoomWidgetConfiguration {
    static let stateEventTypes = ["im.vector.modular.widgets", "m.widget"]
}

struct NitroRoomWidgetOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int
    
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased() else {
            return nil
        }
        
        self.scheme = scheme
        self.host = host
        port = url.port ?? 443
    }
    
    var serialized: String {
        port == 443 ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
    
    func matches(_ url: URL) -> Bool {
        self == NitroRoomWidgetOrigin(url: url)
    }
    
    func matches(scheme: String, host: String, port: Int) -> Bool {
        let effectivePort = port == 0 ? 443 : port
        return self.scheme == scheme.lowercased()
            && self.host == host.lowercased()
            && self.port == effectivePort
    }
}

protocol NitroRoomWidgetRoomProxyProtocol: AnyObject {
    var nitroRoomWidgetsPublisher: CurrentValuePublisher<[NitroRoomWidget], Never> { get }
    func nitroRoomWidgetDriver() -> NitroRoomWidgetDriverProtocol
}

enum NitroRoomWidgetParser {
    private static let trustedTypePrefix = "com.nitrovery.c2m."
    private static let trustedHosts = ["artifacts.nitrovery.com", "pub-artifacts.nitrovery.com"]
    private static let decoder = JSONDecoder()
    
    static func parse(_ events: [String]) -> [NitroRoomWidget] {
        var widgetsByID = [String: NitroRoomWidget]()
        
        for eventJSON in events {
            guard let data = eventJSON.data(using: .utf8),
                  let event = try? decoder.decode(StateEvent.self, from: data),
                  !event.stateKey.isEmpty,
                  let widget = makeWidget(event: event) else {
                continue
            }
            
            widgetsByID[widget.id] = widget
        }
        
        return widgetsByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    
    private static func makeWidget(event: StateEvent) -> NitroRoomWidget? {
        let content = event.content
        guard content.type.hasPrefix(trustedTypePrefix),
              let url = URL(string: content.url),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              trustedHosts.contains(host) else {
            return nil
        }
        
        let id = content.id?.nilIfEmpty ?? event.stateKey
        guard !id.isEmpty else { return nil }
        
        return NitroRoomWidget(id: id,
                               name: content.name?.nilIfEmpty ?? content.data?.title?.nilIfEmpty ?? content.type,
                               type: content.type,
                               url: url,
                               waitForIframeLoad: content.waitForIframeLoad ?? false)
    }
    
    private struct StateEvent: Decodable {
        let stateKey: String
        let content: Content
        
        enum CodingKeys: String, CodingKey {
            case stateKey = "state_key"
            case content
        }
    }
    
    private struct Content: Decodable {
        let id: String?
        let name: String?
        let type: String
        let url: String
        let waitForIframeLoad: Bool?
        let data: WidgetData?
    }
    
    private struct WidgetData: Decodable {
        let title: String?
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
