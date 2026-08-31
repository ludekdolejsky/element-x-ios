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
    private static let decisiveDragThreshold: CGFloat = 44
    
    @Published private(set) var context: NitroRoomWidgetsScreenViewModel.Context?
    @Published private(set) var layout = NitroRoomWidgetPanelLayout.regular
    
    var isPresented: Bool {
        context != nil
    }
    
    func present(context: NitroRoomWidgetsScreenViewModel.Context, layout: NitroRoomWidgetPanelLayout = .regular) {
        self.context = context
        self.layout = layout
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
    
    func settle(translation: CGFloat, predictedTranslation: CGFloat, availableHeight: CGFloat) {
        let intendedTranslation = abs(predictedTranslation) > abs(translation) ? predictedTranslation : translation
        let proposedHeight = height(availableHeight: availableHeight) + intendedTranslation
        let nearestLayout = NitroRoomWidgetPanelLayout.allCases.min {
            abs(height(for: $0, availableHeight: availableHeight) - proposedHeight)
                < abs(height(for: $1, availableHeight: availableHeight) - proposedHeight)
        } ?? layout
        
        if nearestLayout == layout, abs(intendedTranslation) >= Self.decisiveDragThreshold {
            layout = adjacentLayout(in: intendedTranslation)
        } else {
            layout = nearestLayout
        }
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
    
    private func adjacentLayout(in translation: CGFloat) -> NitroRoomWidgetPanelLayout {
        switch (layout, translation.sign) {
        case (.compact, .plus):
            .regular
        case (.regular, .plus):
            .expanded
        case (.expanded, .minus):
            .regular
        case (.regular, .minus):
            .compact
        default:
            layout
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
