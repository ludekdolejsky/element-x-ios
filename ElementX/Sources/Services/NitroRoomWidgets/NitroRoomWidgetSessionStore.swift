//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NitroRoomWidgetPanelLayout: Equatable {
    case half
    case full
}

struct NitroRoomWidgetSession: Equatable {
    let widgetID: String?
    let layout: NitroRoomWidgetPanelLayout
}

protocol NitroRoomWidgetSessionStoreProtocol: AnyObject {
    func session(for roomID: String) -> NitroRoomWidgetSession?
    func preferredLayout(for roomID: String) -> NitroRoomWidgetPanelLayout?
    func primaryWidgetID(in widgets: [NitroRoomWidget]) -> String?
    func setSession(_ session: NitroRoomWidgetSession, for roomID: String)
    func setPreferredLayout(_ layout: NitroRoomWidgetPanelLayout, for roomID: String)
    func removeSession(for roomID: String)
}

final class NitroRoomWidgetSessionStore: NitroRoomWidgetSessionStoreProtocol {
    private var sessions = [String: NitroRoomWidgetSession]()
    private var preferredLayouts = [String: NitroRoomWidgetPanelLayout]()
    
    func session(for roomID: String) -> NitroRoomWidgetSession? {
        sessions[roomID]
    }
    
    func preferredLayout(for roomID: String) -> NitroRoomWidgetPanelLayout? {
        preferredLayouts[roomID]
    }
    
    func primaryWidgetID(in widgets: [NitroRoomWidget]) -> String? {
        widgets.count == 1 ? widgets[0].id : nil
    }
    
    func setSession(_ session: NitroRoomWidgetSession, for roomID: String) {
        sessions[roomID] = session
        preferredLayouts[roomID] = session.layout
    }
    
    func setPreferredLayout(_ layout: NitroRoomWidgetPanelLayout, for roomID: String) {
        preferredLayouts[roomID] = layout
    }
    
    func removeSession(for roomID: String) {
        sessions[roomID] = nil
    }
}
