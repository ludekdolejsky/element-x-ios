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
    func primaryWidgetID(in widgets: [NitroRoomWidget], for roomID: String) -> String?
    func setSession(_ session: NitroRoomWidgetSession, for roomID: String)
    func setPreferredWidgetID(_ widgetID: String, for roomID: String)
    func removeSession(for roomID: String)
}

final class NitroRoomWidgetSessionStore: NitroRoomWidgetSessionStoreProtocol {
    private var sessions = [String: NitroRoomWidgetSession]()
    private var preferredWidgetIDs = [String: String]()

    func session(for roomID: String) -> NitroRoomWidgetSession? {
        sessions[roomID]
    }

    func primaryWidgetID(in widgets: [NitroRoomWidget], for roomID: String) -> String? {
        if let preferredWidgetID = preferredWidgetIDs[roomID], widgets.contains(where: { $0.id == preferredWidgetID }) {
            return preferredWidgetID
        }
        return widgets.count == 1 ? widgets[0].id : nil
    }
    
    func setSession(_ session: NitroRoomWidgetSession, for roomID: String) {
        sessions[roomID] = session
        if let widgetID = session.widgetID {
            preferredWidgetIDs[roomID] = widgetID
        }
    }

    func setPreferredWidgetID(_ widgetID: String, for roomID: String) {
        preferredWidgetIDs[roomID] = widgetID
    }
    
    func removeSession(for roomID: String) {
        sessions[roomID] = nil
    }
}
