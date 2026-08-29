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

enum NitroRoomWidgetPanelLayout: CaseIterable, Equatable {
    case compact
    case regular
    case expanded
}

final class NitroRoomWidgetPanelController: ObservableObject {
    @Published private(set) var context: NitroRoomWidgetsScreenViewModel.Context?
    @Published private(set) var layout = NitroRoomWidgetPanelLayout.regular
    
    func present(context: NitroRoomWidgetsScreenViewModel.Context) {
        self.context = context
        layout = .regular
    }
    
    func dismiss() {
        context = nil
        layout = .regular
    }
    
    func expand() {
        switch layout {
        case .compact:
            layout = .regular
        case .regular, .expanded:
            layout = .expanded
        }
    }
    
    func collapse() {
        switch layout {
        case .compact, .regular:
            layout = .compact
        case .expanded:
            layout = .regular
        }
    }
    
    func settle(proposedHeight: CGFloat, availableHeight: CGFloat) {
        layout = NitroRoomWidgetPanelLayout.allCases.min {
            abs(height(for: $0, availableHeight: availableHeight) - proposedHeight)
                < abs(height(for: $1, availableHeight: availableHeight) - proposedHeight)
        } ?? .regular
    }
    
    func height(availableHeight: CGFloat) -> CGFloat {
        height(for: layout, availableHeight: availableHeight)
    }
    
    private func height(for layout: NitroRoomWidgetPanelLayout, availableHeight: CGFloat) -> CGFloat {
        let compactHeight: CGFloat = 52
        let usableHeight = max(availableHeight, compactHeight)
        let regularHeight = min(max(usableHeight * 0.34, 180), min(320, usableHeight * 0.48))
        
        switch layout {
        case .compact:
            return compactHeight
        case .regular:
            return regularHeight
        case .expanded:
            return max(regularHeight, usableHeight * 0.78)
        }
    }
}
