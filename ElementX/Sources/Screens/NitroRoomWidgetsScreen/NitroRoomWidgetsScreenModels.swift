//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import CoreGraphics
import Foundation

typealias NitroRoomWidgetJavaScriptEvaluator = (String) async throws -> Void
typealias NitroRoomWidgetDocumentID = UUID

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
    case webViewStarted(NitroRoomWidgetDocumentID)
    case webViewReady(NitroRoomWidgetDocumentID, NitroRoomWidgetJavaScriptEvaluator)
    case webViewStopped(NitroRoomWidgetDocumentID)
    case webViewFailed(NitroRoomWidgetDocumentID?)
    case widgetReadinessTimedOut(NitroRoomWidgetDocumentID)
    case widgetMessage(String, documentID: NitroRoomWidgetDocumentID, javaScriptEvaluator: NitroRoomWidgetJavaScriptEvaluator)
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

final class NitroRoomWidgetPanelController: ObservableObject {
    @Published private(set) var context: NitroRoomWidgetsScreenViewModel.Context?
    @Published private(set) var layout = NitroRoomWidgetPanelLayout.full
    
    var isPresented: Bool {
        context != nil
    }
    
    func present(context: NitroRoomWidgetsScreenViewModel.Context, layout: NitroRoomWidgetPanelLayout = .full) {
        self.context = context
        self.layout = layout
    }
    
    func dismiss() {
        context = nil
        layout = .full
    }
    
    func expand() {
        layout = .full
    }
    
    func collapse() {
        layout = .half
    }
    
    func height(availableHeight: CGFloat) -> CGFloat {
        height(for: layout, availableHeight: availableHeight)
    }
    
    private func height(for layout: NitroRoomWidgetPanelLayout, availableHeight: CGFloat) -> CGFloat {
        let usableHeight = max(availableHeight, 0)
        
        switch layout {
        case .half:
            return max(usableHeight * 0.5, min(44, usableHeight))
        case .full:
            return usableHeight
        }
    }
}

extension NitroRoomWidgetsScreenDestination {
    var widgetID: String? {
        switch self {
        case .list:
            nil
        case .loading(let widget), .widget(let widget, _), .error(let widget):
            widget.id
        }
    }
}
