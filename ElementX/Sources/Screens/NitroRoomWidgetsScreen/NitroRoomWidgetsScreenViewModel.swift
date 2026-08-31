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
        let documentID: NitroRoomWidgetDocumentID?
    }

    private struct PendingWidgetMessage {
        let body: String
        let documentID: NitroRoomWidgetDocumentID
    }
    
    private let driverFactory: () -> NitroRoomWidgetDriverProtocol?
    private let colorScheme: ColorScheme
    private let actionsSubject = PassthroughSubject<NitroRoomWidgetsScreenViewModelAction, Never>()
    private var driver: NitroRoomWidgetDriverProtocol?
    private var driverMessageCancellable: AnyCancellable?
    private var pendingDriverMessages = [PendingDriverMessage]()
    private var pendingWidgetMessages = [PendingWidgetMessage]()
    private var driverSessionID: UUID?
    private var driverMessagePumpID: UUID?
    private var activeDocumentID: NitroRoomWidgetDocumentID?
    private var hasStartedWebViewDocument = false
    private var navigationCapabilityRequested = false
    
    @CancellableTask private var startTask: Task<Void, Never>?
    @CancellableTask private var driverMessageTask: Task<Void, Never>?
    @CancellableTask private var widgetMessageTask: Task<Void, Never>?
    
    var actions: AnyPublisher<NitroRoomWidgetsScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(widgets: [NitroRoomWidget],
         initialWidgetID: String? = nil,
         colorScheme: ColorScheme,
         driverFactory: @escaping () -> NitroRoomWidgetDriverProtocol?) {
        self.driverFactory = driverFactory
        self.colorScheme = colorScheme
        let initialWidget = widgets.first { $0.id == initialWidgetID }
        let destination: NitroRoomWidgetsScreenDestination = if let initialWidget {
            .loading(initialWidget)
        } else if widgets.count == 1 {
            .loading(widgets[0])
        } else {
            .list
        }
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
        case .webViewStarted(let documentID):
            startWebViewDocument(documentID)
        case .webViewReady(let documentID, let javaScriptEvaluator):
            guard activeDocumentID == documentID else { return }
            state.bindings.javaScriptEvaluator = javaScriptEvaluator
            startDriverMessagePumpIfNeeded()
        case .webViewStopped(let documentID):
            guard activeDocumentID == documentID else { return }
            activeDocumentID = nil
            state.bindings.javaScriptEvaluator = nil
            driverMessagePumpID = nil
            driverMessageTask = nil
            widgetMessageTask = nil
            pendingWidgetMessages.removeAll()
        case .webViewFailed(let documentID):
            guard activeDocumentID == documentID else { return }
            guard let driverSessionID else { return }
            failCurrentWidget(sessionID: driverSessionID)
        case .widgetMessage(let message, let documentID, let javaScriptEvaluator):
            guard activeDocumentID == documentID else { return }
            state.bindings.javaScriptEvaluator = javaScriptEvaluator
            startDriverMessagePumpIfNeeded()
            handleWidgetMessage(message, documentID: documentID)
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
        activeDocumentID = nil
        hasStartedWebViewDocument = false
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
        subscribeToDriver(driver, sessionID: driverSessionID)
        
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
        pendingDriverMessages.append(.init(body: body, navigationURL: navigationURL, documentID: activeDocumentID))
        startDriverMessagePumpIfNeeded()
    }
    
    private func handleWidgetMessage(_ message: String, documentID: NitroRoomWidgetDocumentID) {
        guard let driverSessionID else { return }
        if let request = NitroRoomWidgetNavigationBridge.navigationRequest(from: message) {
            enqueueDriverMessage(request.response, sessionID: driverSessionID, navigationURL: request.url)
            return
        }
        
        if NitroRoomWidgetNavigationBridge.requestsNavigationCapability(message) {
            navigationCapabilityRequested = true
        }
        enqueueWidgetMessage(message, documentID: documentID)
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
              let activeDocumentID,
              !pendingDriverMessages.isEmpty {
            let message = pendingDriverMessages[0]
            guard message.documentID == activeDocumentID else {
                pendingDriverMessages.removeFirst()
                continue
            }
            let wasPosted = await postToWidget(message.body, using: javaScriptEvaluator)
            guard driverSessionID == sessionID,
                  driverMessagePumpID == pumpID,
                  self.activeDocumentID == activeDocumentID else { return }
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
    
    private func enqueueWidgetMessage(_ message: String, documentID: NitroRoomWidgetDocumentID) {
        guard let driverSessionID else { return }
        guard pendingWidgetMessages.count < Self.maximumPendingMessageCount else {
            MXLog.error("Nitro room widget message queue exceeded its limit.")
            failCurrentWidget(sessionID: driverSessionID)
            return
        }
        
        pendingWidgetMessages.append(.init(body: message, documentID: documentID))
        guard widgetMessageTask == nil, let driver else { return }
        widgetMessageTask = Task { [weak self, driver] in
            await self?.sendWidgetMessages(to: driver, sessionID: driverSessionID)
        }
    }
    
    private func sendWidgetMessages(to driver: NitroRoomWidgetDriverProtocol, sessionID: UUID) async {
        while !Task.isCancelled,
              driverSessionID == sessionID,
              let activeDocumentID,
              !pendingWidgetMessages.isEmpty {
            let message = pendingWidgetMessages[0]
            guard message.documentID == activeDocumentID else {
                pendingWidgetMessages.removeFirst()
                continue
            }
            await driver.send(message.body)
            guard !Task.isCancelled,
                  driverSessionID == sessionID,
                  self.activeDocumentID == activeDocumentID else { return }
            pendingWidgetMessages.removeFirst()
        }
        
        guard driverSessionID == sessionID else { return }
        widgetMessageTask = nil
    }
    
    private func startWebViewDocument(_ documentID: NitroRoomWidgetDocumentID) {
        let shouldRestartDriver = hasStartedWebViewDocument
        hasStartedWebViewDocument = true
        activeDocumentID = documentID
        navigationCapabilityRequested = false
        state.bindings.javaScriptEvaluator = nil
        driverMessagePumpID = nil
        driverMessageTask = nil
        widgetMessageTask = nil
        pendingWidgetMessages.removeAll()

        if shouldRestartDriver {
            pendingDriverMessages.removeAll()
            restartDriver()
        } else {
            pendingDriverMessages = pendingDriverMessages.map {
                .init(body: $0.body, navigationURL: $0.navigationURL, documentID: documentID)
            }
        }
    }

    private func restartDriver() {
        guard let driver else { return }
        driverMessageCancellable = nil
        let sessionID = UUID()
        driverSessionID = sessionID
        subscribeToDriver(driver, sessionID: sessionID)
        guard case .success = driver.restart() else {
            failCurrentWidget(sessionID: sessionID)
            return
        }
    }

    private func subscribeToDriver(_ driver: NitroRoomWidgetDriverProtocol, sessionID: UUID) {
        driverMessageCancellable = driver.messagePublisher.sink { [weak self] message in
            self?.enqueueDriverMessage(message, sessionID: sessionID)
        }
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
        } catch is CancellationError {
            return false
        } catch {
            MXLog.error("Failed forwarding a message to a Nitro room widget: \(error)")
            return false
        }
    }
}
