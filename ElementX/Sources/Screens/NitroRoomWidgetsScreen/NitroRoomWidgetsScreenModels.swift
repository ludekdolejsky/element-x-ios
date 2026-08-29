//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

typealias NitroRoomWidgetJavaScriptEvaluator = (String) async throws -> Void

enum NitroRoomWidgetsScreenViewModelAction {
    case dismiss
    case navigate(URL)
}

enum NitroRoomWidgetsScreenViewAction {
    case appeared
    case disappeared
    case dismiss
    case select(NitroRoomWidget)
    case retry
    case webViewReady(NitroRoomWidgetJavaScriptEvaluator)
    case webViewStopped
    case webViewFailed
    case widgetMessage(String)
}

enum NitroRoomWidgetsScreenDestination: Equatable, Sendable {
    case list
    case loading(NitroRoomWidget)
    case widget(NitroRoomWidget, URL)
    case error(NitroRoomWidget)
}

struct NitroRoomWidgetsScreenViewState: BindableState {
    let widgets: [NitroRoomWidget]
    var destination: NitroRoomWidgetsScreenDestination
    var bindings = NitroRoomWidgetsScreenViewStateBindings()
}

struct NitroRoomWidgetsScreenViewStateBindings {
    var javaScriptEvaluator: NitroRoomWidgetJavaScriptEvaluator?
}
