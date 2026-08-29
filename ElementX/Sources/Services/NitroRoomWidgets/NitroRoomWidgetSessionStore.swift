//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NitroRoomWidgetPanelLayout: CaseIterable, Equatable {
    case compact
    case regular
    case expanded
}

struct NitroRoomWidgetSession: Equatable {
    let widgetID: String?
    let layout: NitroRoomWidgetPanelLayout
}

protocol NitroRoomWidgetSessionStoreProtocol: AnyObject {
    func session(for roomID: String) -> NitroRoomWidgetSession?
    func setSession(_ session: NitroRoomWidgetSession, for roomID: String)
    func removeSession(for roomID: String)
}

final class NitroRoomWidgetSessionStore: NitroRoomWidgetSessionStoreProtocol {
    private var sessions = [String: NitroRoomWidgetSession]()
    
    func session(for roomID: String) -> NitroRoomWidgetSession? {
        sessions[roomID]
    }
    
    func setSession(_ session: NitroRoomWidgetSession, for roomID: String) {
        sessions[roomID] = session
    }
    
    func removeSession(for roomID: String) {
        sessions[roomID] = nil
    }
}
