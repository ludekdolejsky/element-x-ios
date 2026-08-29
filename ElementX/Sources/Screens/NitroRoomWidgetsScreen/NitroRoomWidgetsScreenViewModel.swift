//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import SwiftUI

typealias NitroRoomWidgetsScreenViewModelType = StateStoreViewModelV2<NitroRoomWidgetsScreenViewState, NitroRoomWidgetsScreenViewAction>

final class NitroRoomWidgetsScreenViewModel: NitroRoomWidgetsScreenViewModelType, NitroRoomWidgetsScreenViewModelProtocol {
    private static let maximumPendingMessageCount = 256
    
    private struct PendingDriverMessage {
        let body: String
        let navigationURL: URL?
    }
    
    private let driverFactory: () -> NitroRoomWidgetDriverProtocol?
    private let colorScheme: ColorScheme
    private let actionsSubject = PassthroughSubject<NitroRoomWidgetsScreenViewModelAction, Never>()
    private var driver: NitroRoomWidgetDriverProtocol?
    private var driverMessageCancellable: AnyCancellable?
    private var pendingDriverMessages = [PendingDriverMessage]()
    private var pendingWidgetMessages = [String]()
    private var driverSessionID: UUID?
    private var driverMessagePumpID: UUID?
    private var navigationCapabilityRequested = false
    
    @CancellableTask private var startTask: Task<Void, Never>?
    @CancellableTask private var driverMessageTask: Task<Void, Never>?
    @CancellableTask private var widgetMessageTask: Task<Void, Never>?
    
    var actions: AnyPublisher<NitroRoomWidgetsScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(widgets: [NitroRoomWidget],
         colorScheme: ColorScheme,
         driverFactory: @escaping () -> NitroRoomWidgetDriverProtocol?) {
        self.driverFactory = driverFactory
        self.colorScheme = colorScheme
        let destination: NitroRoomWidgetsScreenDestination = widgets.count == 1 ? .loading(widgets[0]) : .list
        super.init(initialViewState: .init(widgets: widgets, destination: destination))
    }
    
    override func process(viewAction: NitroRoomWidgetsScreenViewAction) {
        switch viewAction {
        case .appeared:
            if case .loading(let widget) = state.destination, startTask == nil {
                start(widget)
            }
        case .disappeared:
            stop()
        case .dismiss:
            actionsSubject.send(.dismiss)
        case .select(let widget):
            start(widget)
        case .retry:
            guard case .error(let widget) = state.destination else { return }
            start(widget)
        case .webViewReady(let javaScriptEvaluator):
            state.bindings.javaScriptEvaluator = javaScriptEvaluator
            startDriverMessagePumpIfNeeded()
        case .webViewStopped:
            state.bindings.javaScriptEvaluator = nil
            driverMessagePumpID = nil
            driverMessageTask = nil
        case .webViewFailed:
            guard let driverSessionID else { return }
            failCurrentWidget(sessionID: driverSessionID)
        case .widgetMessage(let message):
            handleWidgetMessage(message)
        }
    }
    
    func stop() {
        startTask = nil
        driverMessageCancellable = nil
        driverMessagePumpID = nil
        driverMessageTask = nil
        widgetMessageTask = nil
        pendingDriverMessages.removeAll()
        pendingWidgetMessages.removeAll()
        navigationCapabilityRequested = false
        driverSessionID = nil
        driver?.stop()
        driver = nil
    }
    
    private func start(_ widget: NitroRoomWidget) {
        stop()
        state.destination = .loading(widget)
        
        guard let driver = driverFactory() else {
            state.destination = .error(widget)
            return
        }
        self.driver = driver
        let driverSessionID = UUID()
        self.driverSessionID = driverSessionID
        driverMessageCancellable = driver.messagePublisher.sink { [weak self] message in
            self?.enqueueDriverMessage(message, sessionID: driverSessionID)
        }
        
        startTask = Task { [weak self, driver, colorScheme] in
            let result = await driver.start(widget: widget, colorScheme: colorScheme)
            guard !Task.isCancelled else {
                driver.stop()
                return
            }
            guard let self else {
                driver.stop()
                return
            }
            guard case .loading(let loadingWidget) = state.destination, loadingWidget.id == widget.id else { return }
            
            switch result {
            case .success(let url):
                state.destination = .widget(widget, url)
            case .failure:
                state.destination = .error(widget)
            }
            startTask = nil
        }
    }
    
    private func enqueueDriverMessage(_ message: String, sessionID: UUID, navigationURL: URL? = nil) {
        guard driverSessionID == sessionID else { return }
        guard pendingDriverMessages.count < Self.maximumPendingMessageCount else {
            MXLog.error("Nitro room widget message queue exceeded its limit.")
            failCurrentWidget(sessionID: sessionID)
            return
        }
        
        let body = NitroRoomWidgetNavigationBridge.addingNavigationSupport(to: message,
                                                                           capabilityRequested: navigationCapabilityRequested)
        pendingDriverMessages.append(.init(body: body, navigationURL: navigationURL))
        startDriverMessagePumpIfNeeded()
    }
    
    private func handleWidgetMessage(_ message: String) {
        guard let driverSessionID else { return }
        if let request = NitroRoomWidgetNavigationBridge.navigationRequest(from: message) {
            enqueueDriverMessage(request.response, sessionID: driverSessionID, navigationURL: request.url)
            return
        }
        
        if NitroRoomWidgetNavigationBridge.requestsNavigationCapability(message) {
            navigationCapabilityRequested = true
        }
        enqueueWidgetMessage(message)
    }
    
    private func startDriverMessagePumpIfNeeded() {
        guard driverMessageTask == nil,
              state.bindings.javaScriptEvaluator != nil,
              !pendingDriverMessages.isEmpty,
              let driverSessionID else {
            return
        }
        
        let pumpID = UUID()
        driverMessagePumpID = pumpID
        driverMessageTask = Task { [weak self] in
            await self?.forwardDriverMessages(sessionID: driverSessionID, pumpID: pumpID)
        }
    }
    
    private func forwardDriverMessages(sessionID: UUID, pumpID: UUID) async {
        while !Task.isCancelled,
              driverSessionID == sessionID,
              driverMessagePumpID == pumpID,
              let javaScriptEvaluator = state.bindings.javaScriptEvaluator,
              !pendingDriverMessages.isEmpty {
            let message = pendingDriverMessages[0]
            let wasPosted = await postToWidget(message.body, using: javaScriptEvaluator)
            guard driverSessionID == sessionID, driverMessagePumpID == pumpID else { return }
            guard wasPosted else {
                failCurrentWidget(sessionID: sessionID)
                return
            }
            pendingDriverMessages.removeFirst()
            if let navigationURL = message.navigationURL {
                actionsSubject.send(.navigate(navigationURL))
            }
        }
        
        guard driverSessionID == sessionID, driverMessagePumpID == pumpID else { return }
        driverMessagePumpID = nil
        driverMessageTask = nil
    }
    
    private func enqueueWidgetMessage(_ message: String) {
        guard let driverSessionID else { return }
        guard pendingWidgetMessages.count < Self.maximumPendingMessageCount else {
            MXLog.error("Nitro room widget message queue exceeded its limit.")
            failCurrentWidget(sessionID: driverSessionID)
            return
        }
        
        pendingWidgetMessages.append(message)
        guard widgetMessageTask == nil, let driver else { return }
        widgetMessageTask = Task { [weak self, driver] in
            await self?.sendWidgetMessages(to: driver, sessionID: driverSessionID)
        }
    }
    
    private func sendWidgetMessages(to driver: NitroRoomWidgetDriverProtocol, sessionID: UUID) async {
        while !Task.isCancelled, driverSessionID == sessionID, !pendingWidgetMessages.isEmpty {
            let message = pendingWidgetMessages.removeFirst()
            await driver.send(message)
        }
        
        guard driverSessionID == sessionID else { return }
        widgetMessageTask = nil
    }
    
    private func failCurrentWidget(sessionID: UUID) {
        guard driverSessionID == sessionID else { return }
        let widget: NitroRoomWidget
        switch state.destination {
        case .loading(let currentWidget), .widget(let currentWidget, _), .error(let currentWidget):
            widget = currentWidget
        case .list:
            return
        }
        
        stop()
        state.destination = .error(widget)
    }
    
    private func postToWidget(_ message: String, using javaScriptEvaluator: NitroRoomWidgetJavaScriptEvaluator) async -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard case .widget(_, let url) = state.destination,
              let origin = NitroRoomWidgetOrigin(url: url),
              let originData = try? encoder.encode(origin.serialized),
              let originLiteral = String(data: originData, encoding: .utf8) else {
            return false
        }
        
        do {
            try await javaScriptEvaluator("window.postMessage(\(message), \(originLiteral))")
            return true
        } catch {
            MXLog.error("Failed forwarding a message to a Nitro room widget: \(error)")
            return false
        }
    }
}
