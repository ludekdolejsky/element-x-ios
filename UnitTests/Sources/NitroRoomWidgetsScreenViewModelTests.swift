//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import SwiftUI
import Testing

struct NitroRoomWidgetsScreenViewModelTests {
    @Test
    func opensSingleWidgetAndStopsDriver() async throws {
        let widget = try widget(id: "cockpit")
        let driver = NitroRoomWidgetDriverMock()
        let viewModel = NitroRoomWidgetsScreenViewModel(widgets: [widget], colorScheme: .dark) { driver }
        defer { viewModel.stop() }
        let expectedURL = try #require(URL(string: "https://pub-artifacts.nitrovery.com/open"))
        let destination = deferFulfillment(viewModel.context.observe(\.viewState.destination)) {
            $0 == .widget(widget, expectedURL)
        }
        
        viewModel.context.send(viewAction: .appeared)
        try await destination.fulfill()
        viewModel.stop()
        
        #expect(driver.startedWidgets == [widget])
        #expect(viewModel.context.viewState.destination == .widget(widget, expectedURL))
        #expect(driver.stopCallCount >= 1)
    }
    
    @Test
    func multipleWidgetsWaitForSelection() throws {
        let driver = NitroRoomWidgetDriverMock()
        let viewModel = try NitroRoomWidgetsScreenViewModel(widgets: [widget(id: "a"), widget(id: "b")], colorScheme: .light) { driver }
        
        viewModel.context.send(viewAction: .appeared)
        
        #expect(viewModel.context.viewState.destination == .list)
        #expect(driver.startedWidgets.isEmpty)
    }
    
    @Test
    func sendsWidgetMessagesSerially() async throws {
        let widget = try widget(id: "cockpit")
        let driver = NitroRoomWidgetDriverMock()
        let viewModel = NitroRoomWidgetsScreenViewModel(widgets: [widget], colorScheme: .dark) { driver }
        defer { viewModel.stop() }
        let expectedURL = try #require(URL(string: "https://pub-artifacts.nitrovery.com/open"))
        let destination = deferFulfillment(viewModel.context.observe(\.viewState.destination)) {
            $0 == .widget(widget, expectedURL)
        }
        let (releaseFirstMessage, releaseFirstMessageContinuation) = AsyncStream<Void>.makeStream()
        driver.onSend = { message in
            guard message == "first" else { return }
            for await _ in releaseFirstMessage {
                break
            }
        }
        
        viewModel.context.send(viewAction: .appeared)
        try await destination.fulfill()
        
        await waitForConfirmation(timeout: .seconds(1)) { firstMessageStarted in
            driver.onSendStarted = { message in
                guard message == "first" else { return }
                firstMessageStarted()
            }
            viewModel.context.send(viewAction: .widgetMessage("first"))
            viewModel.context.send(viewAction: .widgetMessage("second"))
        }
        #expect(driver.startedMessages == ["first"])
        
        await waitForConfirmation(timeout: .seconds(1)) { secondMessageSent in
            driver.onSendCompleted = { message in
                guard message == "second" else { return }
                secondMessageSent()
            }
            releaseFirstMessageContinuation.yield()
            releaseFirstMessageContinuation.finish()
        }
        
        #expect(driver.sentMessages == ["first", "second"])
    }
    
    @Test
    func buffersDriverMessagesUntilWebViewIsReady() async throws {
        let widget = try widget(id: "cockpit")
        let driver = NitroRoomWidgetDriverMock()
        let message = #"{"api":"toWidget","action":"capabilities"}"#
        driver.messagesToEmitOnStart = [message]
        let viewModel = NitroRoomWidgetsScreenViewModel(widgets: [widget], colorScheme: .dark) { driver }
        defer { viewModel.stop() }
        let expectedURL = try #require(URL(string: "https://pub-artifacts.nitrovery.com/open"))
        let destination = deferFulfillment(viewModel.context.observe(\.viewState.destination)) {
            $0 == .widget(widget, expectedURL)
        }
        var evaluatedScripts = [String]()
        
        viewModel.context.send(viewAction: .appeared)
        try await destination.fulfill()
        #expect(evaluatedScripts.isEmpty)
        
        await waitForConfirmation(timeout: .seconds(1)) { messageForwarded in
            viewModel.context.send(viewAction: .webViewReady { script in
                evaluatedScripts.append(script)
                messageForwarded()
            })
        }
        
        #expect(evaluatedScripts == ["window.postMessage(\(message), \"https://pub-artifacts.nitrovery.com\")"])
    }
    
    @Test
    func keepsDriverMessageQueuedWhenWebViewStopsDuringEvaluation() async throws {
        let widget = try widget(id: "cockpit")
        let driver = NitroRoomWidgetDriverMock()
        let message = #"{"api":"toWidget","action":"capabilities"}"#
        driver.messagesToEmitOnStart = [message]
        let viewModel = NitroRoomWidgetsScreenViewModel(widgets: [widget], colorScheme: .dark) { driver }
        defer { viewModel.stop() }
        let expectedURL = try #require(URL(string: "https://pub-artifacts.nitrovery.com/open"))
        let destination = deferFulfillment(viewModel.context.observe(\.viewState.destination)) {
            $0 == .widget(widget, expectedURL)
        }
        let (blockedEvaluation, blockedEvaluationContinuation) = AsyncStream<Void>.makeStream()
        var evaluatedScripts = [String]()
        
        viewModel.context.send(viewAction: .appeared)
        try await destination.fulfill()
        
        await waitForConfirmation(timeout: .seconds(1)) { evaluationStarted in
            viewModel.context.send(viewAction: .webViewReady { script in
                evaluatedScripts.append(script)
                evaluationStarted()
                for await _ in blockedEvaluation { }
            })
        }
        
        viewModel.context.send(viewAction: .webViewStopped)
        blockedEvaluationContinuation.finish()
        
        await waitForConfirmation(timeout: .seconds(1)) { messageForwarded in
            viewModel.context.send(viewAction: .webViewReady { script in
                evaluatedScripts.append(script)
                messageForwarded()
            })
        }
        
        #expect(evaluatedScripts == [
            "window.postMessage(\(message), \"https://pub-artifacts.nitrovery.com\")",
            "window.postMessage(\(message), \"https://pub-artifacts.nitrovery.com\")"
        ])
    }
    
    @Test
    func webViewFailureStopsDriverAndShowsRetry() async throws {
        let widget = try widget(id: "cockpit")
        let driver = NitroRoomWidgetDriverMock()
        let viewModel = NitroRoomWidgetsScreenViewModel(widgets: [widget], colorScheme: .dark) { driver }
        defer { viewModel.stop() }
        let expectedURL = try #require(URL(string: "https://pub-artifacts.nitrovery.com/open"))
        let destination = deferFulfillment(viewModel.context.observe(\.viewState.destination)) {
            $0 == .widget(widget, expectedURL)
        }
        
        viewModel.context.send(viewAction: .appeared)
        try await destination.fulfill()
        viewModel.context.send(viewAction: .webViewFailed)
        
        #expect(viewModel.context.viewState.destination == .error(widget))
        #expect(driver.stopCallCount >= 1)
    }
    
    @Test
    func handlesNavigationWithoutForwardingItToTheRustDriver() async throws {
        let widget = try widget(id: "cockpit")
        let driver = NitroRoomWidgetDriverMock()
        let viewModel = NitroRoomWidgetsScreenViewModel(widgets: [widget], colorScheme: .dark) { driver }
        defer { viewModel.stop() }
        let expectedURL = try #require(URL(string: "https://matrix.to/#/!room:example.org/$event:example.org"))
        let destination = deferFulfillment(viewModel.context.observe(\.viewState.destination)) {
            guard case .widget = $0 else { return false }
            return true
        }
        let navigation = deferFulfillment(viewModel.actions) { action in
            guard case .navigate(let url) = action else { return false }
            return url == expectedURL
        }
        var evaluatedScripts = [String]()
        
        viewModel.context.send(viewAction: .appeared)
        try await destination.fulfill()
        viewModel.context.send(viewAction: .webViewReady { script in
            evaluatedScripts.append(script)
        })
        let message = #"{"api":"fromWidget","widgetId":"cockpit","requestId":"request","action":"org.matrix.msc2931.navigate","data":{"uri":"https://matrix.to/#/!room:example.org/$event:example.org"}}"#
        viewModel.context.send(viewAction: .widgetMessage(message))
        try await navigation.fulfill()
        
        #expect(evaluatedScripts.count == 1)
        if let script = evaluatedScripts.first {
            #expect(script.contains("\"response\":{}"))
        }
        #expect(driver.startedMessages.isEmpty)
    }
    
    private func widget(id: String) throws -> NitroRoomWidget {
        try .init(id: id,
                  name: id,
                  type: "com.nitrovery.c2m.\(id)",
                  url: #require(URL(string: "https://pub-artifacts.nitrovery.com/\(id)")),
                  waitForIframeLoad: false)
    }
}

private final class NitroRoomWidgetDriverMock: NitroRoomWidgetDriverProtocol {
    private let messageSubject = PassthroughSubject<String, Never>()
    var startedWidgets = [NitroRoomWidget]()
    var messagesToEmitOnStart = [String]()
    var startedMessages = [String]()
    var sentMessages = [String]()
    var stopCallCount = 0
    var onSend: ((String) async -> Void)?
    var onSendStarted: ((String) -> Void)?
    var onSendCompleted: ((String) -> Void)?
    
    var messagePublisher: AnyPublisher<String, Never> {
        messageSubject.eraseToAnyPublisher()
    }
    
    func start(widget: NitroRoomWidget, colorScheme: ColorScheme) async -> Result<URL, NitroRoomWidgetDriverError> {
        startedWidgets.append(widget)
        messagesToEmitOnStart.forEach(messageSubject.send)
        guard let url = URL(string: "https://pub-artifacts.nitrovery.com/open") else {
            return .failure(.invalidURL)
        }
        return .success(url)
    }
    
    func send(_ message: String) async {
        startedMessages.append(message)
        onSendStarted?(message)
        await onSend?(message)
        sentMessages.append(message)
        onSendCompleted?(message)
    }
    
    func stop() {
        stopCallCount += 1
    }
}
