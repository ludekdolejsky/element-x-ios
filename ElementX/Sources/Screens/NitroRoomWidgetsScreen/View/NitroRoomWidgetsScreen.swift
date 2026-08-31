//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI
import WebKit

struct NitroRoomWidgetsScreen: View {
    @Bindable var context: NitroRoomWidgetsScreenViewModel.Context
    
    var body: some View {
        ElementNavigationStack {
            NitroRoomWidgetContent(context: context)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.compound.bgCanvasDefault)
                .navigationTitle(context.viewState.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            context.send(viewAction: .dismiss)
                        } label: {
                            CompoundIcon(\.close)
                        }
                    }
                }
        }
        .task { context.send(viewAction: .appeared) }
        .onDisappear { context.send(viewAction: .disappeared) }
    }
}

struct NitroRoomWidgetPanel: View {
    @ObservedObject var controller: NitroRoomWidgetPanelController
    let availableHeight: CGFloat
    let onResizeStarted: () -> Void
    
    @GestureState private var resizeGestureState = ResizeGestureState()
    
    init(controller: NitroRoomWidgetPanelController,
         availableHeight: CGFloat,
         onResizeStarted: @escaping () -> Void = { }) {
        self.controller = controller
        self.availableHeight = availableHeight
        self.onResizeStarted = onResizeStarted
    }
    
    var body: some View {
        if let context = controller.context {
            let baseHeight = controller.height(availableHeight: availableHeight)
            let resizeBaseHeight = resizeGestureState.baseHeight ?? baseHeight
            let resizeAvailableHeight = resizeGestureState.availableHeight ?? availableHeight
            let panelHeight = min(max(resizeBaseHeight + resizeGestureState.translation, 52), resizeAvailableHeight)
            
            VStack(spacing: 0) {
                header(context: context)
                Divider()
                NitroRoomWidgetContent(context: context)
                    .id(ObjectIdentifier(context))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: panelHeight)
            .background(Color.compound.bgCanvasDefault)
            .overlay(alignment: .bottom) {
                resizeHandle(baseHeight: baseHeight)
            }
            .clipped()
            .animation(.elementDefault, value: controller.layout)
            .task(id: ObjectIdentifier(context)) { context.send(viewAction: .appeared) }
        }
    }
    
    private func header(context: NitroRoomWidgetsScreenViewModel.Context) -> some View {
        HStack(spacing: 8) {
            CompoundIcon(\.code, size: .small, relativeTo: .compound.bodyLGSemibold)
            Text(context.viewState.title)
                .font(.compound.bodyLGSemibold)
                .lineLimit(1)
            Spacer(minLength: 8)
            
            if controller.layout != .compact {
                Button {
                    controller.collapse()
                } label: {
                    CompoundIcon(\.chevronUp, size: .small, relativeTo: .compound.bodyLG)
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel(UntranslatedL10n.a11yNitroRoomWidgetCollapseIos)
                .buttonStyle(.compound(.tertiary, size: .toolbarIcon))
            }
            
            if controller.layout != .expanded {
                Button {
                    controller.expand()
                } label: {
                    CompoundIcon(\.chevronDown, size: .small, relativeTo: .compound.bodyLG)
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel(UntranslatedL10n.a11yNitroRoomWidgetExpandIos)
                .buttonStyle(.compound(.tertiary, size: .toolbarIcon))
            }
            
            Button {
                context.send(viewAction: .dismiss)
            } label: {
                CompoundIcon(\.close, size: .small, relativeTo: .compound.bodyLG)
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel(L10n.actionClose)
            .buttonStyle(.compound(.tertiary, size: .toolbarIcon))
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
    
    private func resizeHandle(baseHeight: CGFloat) -> some View {
        Color.clear
            .frame(width: 96, height: 32)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(Color.compound.borderInteractiveSecondary)
                    .frame(width: 36, height: 4)
            }
            .gesture(DragGesture(minimumDistance: 4)
                .updating($resizeGestureState) { value, state, _ in
                    if state.baseHeight == nil {
                        state.baseHeight = baseHeight
                        state.availableHeight = availableHeight
                    }
                    state.translation = value.translation.height
                }
                .onChanged { _ in
                    onResizeStarted()
                }
                .onEnded { value in
                    controller.settle(translation: value.translation.height,
                                      predictedTranslation: value.predictedEndTranslation.height,
                                      availableHeight: resizeGestureState.availableHeight ?? availableHeight)
                })
            .accessibilityHidden(true)
    }
}

private struct ResizeGestureState {
    var baseHeight: CGFloat?
    var availableHeight: CGFloat?
    var translation: CGFloat = 0
}

private struct NitroRoomWidgetContent: View {
    let context: NitroRoomWidgetsScreenViewModel.Context
    
    var body: some View {
        switch context.viewState.destination {
        case .list:
            List(context.viewState.widgets) { widget in
                Button {
                    context.send(viewAction: .select(widget))
                } label: {
                    ListRow(label: .default(title: widget.name, icon: \.code), kind: .label)
                }
            }
            .compoundList()
        case .loading:
            ProgressView(UntranslatedL10n.screenNitroRoomWidgetsLoadingIos)
        case .widget(let widget, let url):
            NitroRoomWidgetWebView(widget: widget, url: url, context: context)
                .id(url)
                .ignoresSafeArea(edges: .bottom)
        case .error:
            VStack(spacing: 24) {
                Text(UntranslatedL10n.screenNitroRoomWidgetsErrorIos)
                    .font(.compound.bodyLG)
                Button(UntranslatedL10n.screenNitroRoomWidgetsRetryIos) {
                    context.send(viewAction: .retry)
                }
                .buttonStyle(.compound(.primary, size: .medium))
            }
            .padding(24)
        }
    }
}

private extension NitroRoomWidgetsScreenViewState {
    var title: String {
        switch destination {
        case .list:
            UntranslatedL10n.screenNitroRoomWidgetsTitleIos
        case .loading(let widget), .widget(let widget, _), .error(let widget):
            widget.name
        }
    }
}

private struct NitroRoomWidgetWebView: UIViewRepresentable {
    let widget: NitroRoomWidget
    let url: URL
    let context: NitroRoomWidgetsScreenViewModel.Context
    
    func makeCoordinator() -> Coordinator {
        Coordinator(context: context, widget: widget, allowedURL: url)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(url)
    }
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }
    
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private struct ScriptMessage: Decodable {
            enum Kind: String, Decodable {
                case documentReady
                case widget
                case diagnostic
            }

            let documentID: NitroRoomWidgetDocumentID
            let kind: Kind
            let body: String?

            enum CodingKeys: String, CodingKey {
                case documentID = "document_id"
                case kind
                case body
            }
        }

        private static let handlerName = "widgetAction"
        private static let diagnosticsHandlerName = "widgetDiagnostics"
        private let context: NitroRoomWidgetsScreenViewModel.Context
        private let allowedURL: URL
        private let diagnostics: NitroRoomWidgetDiagnostics
        private var loadedURL: URL?
        private var widgetAPIWatchdogTask: Task<Void, Never>?
        private var documentSequence = 0
        private var widgetMessagesReceived = 0
        private var driverScriptsStarted = 0
        private var driverScriptsCompleted = 0
        private var documentID: NitroRoomWidgetDocumentID?
        private var retiredDocumentIDs = Set<NitroRoomWidgetDocumentID>()
        private var activeNavigation: WKNavigation?
        private var documentIDsByNavigation = [ObjectIdentifier: NitroRoomWidgetDocumentID]()
        let webView: WKWebView
        
        init(context: NitroRoomWidgetsScreenViewModel.Context, widget: NitroRoomWidget, allowedURL: URL) {
            self.context = context
            self.allowedURL = allowedURL
            diagnostics = .init(widgetID: widget.id, url: allowedURL)
            
            let userContentController = WKUserContentController()
            let script = """
            const nitroDocumentID = crypto.randomUUID();
            const postNitroMessage = function(handler, kind, body) {
                handler.postMessage(JSON.stringify({
                    document_id: nitroDocumentID,
                    kind: kind,
                    body: body
                }));
            };
            postNitroMessage(window.webkit.messageHandlers.\(Self.handlerName), 'documentReady');
            window.addEventListener('message', function(event) {
                if (event.source !== window || event.origin !== window.location.origin) {
                    return;
                }
                const data = event.data;
                if ((data.response && data.api === 'toWidget') || (!data.response && data.api === 'fromWidget')) {
                    postNitroMessage(window.webkit.messageHandlers.\(Self.handlerName), 'widget', JSON.stringify(data));
                }
            }, false);
            window.addEventListener('nitro-widget-diagnostic', function(event) {
                const detail = event.detail;
                if (detail && typeof detail === 'object') {
                    postNitroMessage(window.webkit.messageHandlers.\(Self.diagnosticsHandlerName), 'diagnostic', JSON.stringify(detail));
                }
            }, false);
            window.dispatchEvent(new CustomEvent('nitro-widget-diagnostic', {
                detail: { phase: 'diagnostic_bridge_ready', elapsed_ms: 0 }
            }));
            """
            userContentController.addUserScript(.init(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            
            let configuration = WKWebViewConfiguration()
            configuration.userContentController = userContentController
            configuration.applicationNameForUserAgent = InfoPlistReader.main.bundleDisplayName
            webView = WKWebView(frame: .zero, configuration: configuration)
            
            super.init()
            
            userContentController.add(NitroRoomWidgetScriptMessageHandler(self), name: Self.handlerName)
            userContentController.add(NitroRoomWidgetScriptMessageHandler(self), name: Self.diagnosticsHandlerName)
            webView.navigationDelegate = self
            webView.allowsLinkPreview = true
            webView.isInspectable = true
            webView.isOpaque = false
            webView.backgroundColor = .compound.bgCanvasDefault
            webView.scrollView.backgroundColor = .compound.bgCanvasDefault
        }
        
        func stop() {
            stopWidgetAPIWatchdog()
            if let documentID {
                retiredDocumentIDs.insert(documentID)
                context.send(viewAction: .webViewStopped(documentID))
            }
            documentID = nil
            activeNavigation = nil
            documentIDsByNavigation.removeAll()
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.diagnosticsHandlerName)
        }
        
        func load(_ url: URL) {
            guard loadedURL != url else { return }
            loadedURL = url
            webView.load(URLRequest(url: url))
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  isAllowed(message.frameInfo.securityOrigin),
                  let encodedMessage = message.body as? String,
                  let data = encodedMessage.data(using: .utf8),
                  let scriptMessage = try? JSONDecoder().decode(ScriptMessage.self, from: data) else {
                return
            }
            if scriptMessage.kind == .documentReady, message.name == Self.handlerName {
                startDocument(scriptMessage.documentID)
                return
            }
            guard documentID == scriptMessage.documentID,
                  let body = scriptMessage.body else { return }
            if scriptMessage.kind == .diagnostic, message.name == Self.diagnosticsHandlerName {
                let phase = diagnostics.handleJavaScriptMessage(body, bridgeState: bridgeState)
                if phase == "widget_api_ready" || phase == "authorization_ready" {
                    stopWidgetAPIWatchdog()
                }
                return
            }
            guard scriptMessage.kind == .widget, message.name == Self.handlerName else { return }
            widgetMessagesReceived += 1
            context.send(viewAction: .widgetMessage(body,
                                                    documentID: scriptMessage.documentID,
                                                    javaScriptEvaluator: javaScriptEvaluator(for: scriptMessage.documentID)))
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                diagnostics.recordHTTPFailure(statusCode: nil)
                context.send(viewAction: .webViewFailed(documentID))
                return .cancel
            }
            if navigationAction.targetFrame?.isMainFrame == false {
                return .allow
            }
            
            if navigationAction.targetFrame?.isMainFrame == true,
               NitroRoomWidgetOrigin(url: allowedURL)?.matches(url) == true {
                return .allow
            }
            
            if navigationAction.navigationType == .linkActivated {
                await UIApplication.shared.open(url)
            } else {
                context.send(viewAction: .webViewFailed(documentID))
            }
            return .cancel
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            guard navigationResponse.isForMainFrame else { return .allow }
            guard let response = navigationResponse.response as? HTTPURLResponse,
                  (200..<400).contains(response.statusCode) else {
                diagnostics.recordHTTPFailure(statusCode: (navigationResponse.response as? HTTPURLResponse)?.statusCode)
                context.send(viewAction: .webViewFailed(documentID))
                return .cancel
            }
            return .allow
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            stopWidgetAPIWatchdog()
            activeNavigation = navigation
            if let documentID {
                retiredDocumentIDs.insert(documentID)
                context.send(viewAction: .webViewStopped(documentID))
            }
            documentID = nil
            documentSequence += 1
            widgetMessagesReceived = 0
            driverScriptsStarted = 0
            driverScriptsCompleted = 0
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let documentID = documentID(for: navigation), self.documentID == documentID else { return }
            documentIDsByNavigation.removeValue(forKey: ObjectIdentifier(navigation))
            activeNavigation = nil
            guard let url = webView.url, NitroRoomWidgetOrigin(url: allowedURL)?.matches(url) == true else {
                diagnostics.recordHTTPFailure(statusCode: nil)
                context.send(viewAction: .webViewFailed(documentID))
                return
            }
            context.send(viewAction: .webViewReady(documentID, javaScriptEvaluator(for: documentID)))
            startWidgetAPIWatchdog()
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            handleNavigationFailure(error, documentID: documentID(for: navigation))
            documentIDsByNavigation.removeValue(forKey: ObjectIdentifier(navigation))
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            handleNavigationFailure(error, documentID: documentID(for: navigation))
            documentIDsByNavigation.removeValue(forKey: ObjectIdentifier(navigation))
        }
        
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            diagnostics.recordWebContentProcessTermination()
            context.send(viewAction: .webViewFailed(documentID))
        }
        
        private func isAllowed(_ securityOrigin: WKSecurityOrigin) -> Bool {
            guard let allowedOrigin = NitroRoomWidgetOrigin(url: allowedURL) else { return false }
            return allowedOrigin.matches(scheme: securityOrigin.protocol,
                                         host: securityOrigin.host,
                                         port: securityOrigin.port)
        }
        
        private func handleNavigationFailure(_ error: any Error, documentID: NitroRoomWidgetDocumentID?) {
            stopWidgetAPIWatchdog()
            let error = error as NSError
            guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
            diagnostics.recordNavigationFailure(phase: "navigation_failed", error: error)
            context.send(viewAction: .webViewFailed(documentID))
        }

        private func startDocument(_ documentID: NitroRoomWidgetDocumentID) {
            guard !retiredDocumentIDs.contains(documentID), self.documentID != documentID else { return }
            if let currentDocumentID = self.documentID {
                retiredDocumentIDs.insert(currentDocumentID)
                context.send(viewAction: .webViewStopped(currentDocumentID))
            }
            self.documentID = documentID
            if let activeNavigation {
                documentIDsByNavigation[ObjectIdentifier(activeNavigation)] = documentID
            }
            context.send(viewAction: .webViewStarted(documentID))
        }

        private func documentID(for navigation: WKNavigation) -> NitroRoomWidgetDocumentID? {
            documentIDsByNavigation[ObjectIdentifier(navigation)]
        }
        
        private func startWidgetAPIWatchdog() {
            stopWidgetAPIWatchdog()
            widgetAPIWatchdogTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(25))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                diagnostics.recordNativeWidgetAPITimeout(bridgeState: bridgeState)
            }
        }
        
        private func stopWidgetAPIWatchdog() {
            widgetAPIWatchdogTask?.cancel()
            widgetAPIWatchdogTask = nil
        }
        
        private func javaScriptEvaluator(for documentID: NitroRoomWidgetDocumentID) -> NitroRoomWidgetJavaScriptEvaluator {
            { [weak self] script in
                guard let self else { return }
                try await evaluateJavaScript(script, documentID: documentID)
            }
        }

        private func evaluateJavaScript(_ script: String, documentID: NitroRoomWidgetDocumentID) async throws {
            guard self.documentID == documentID else { throw CancellationError() }
            driverScriptsStarted += 1
            try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<Void, any Error>) in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                webView.evaluateJavaScript(script) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        self.driverScriptsCompleted += 1
                        continuation.resume()
                    }
                }
            }
            guard self.documentID == documentID else { throw CancellationError() }
        }
        
        private var bridgeState: NitroRoomWidgetBridgeState {
            .init(documentSequence: documentSequence,
                  widgetMessagesReceived: widgetMessagesReceived,
                  driverScriptsStarted: driverScriptsStarted,
                  driverScriptsCompleted: driverScriptsCompleted)
        }
    }
}

private final class NitroRoomWidgetScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var handler: WKScriptMessageHandler?
    
    init(_ handler: WKScriptMessageHandler) {
        self.handler = handler
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        handler?.userContentController(userContentController, didReceive: message)
    }
}

struct NitroRoomToolsMenuButton: View {
    @Binding var isMenuPresented: Bool
    let longPressAction: (() -> Void)?
    
    var body: some View {
        ZStack {
            CompoundIcon(\.overflowHorizontal)
                .accessibilityHidden(true)
            NitroRoomToolsMenuButtonRepresentable(tapAction: { isMenuPresented = true },
                                                  longPressAction: longPressAction,
                                                  accessibilityLabel: UntranslatedL10n.a11yRoomActionsIos,
                                                  accessibilityLongPressLabel: UntranslatedL10n.screenNitroRoomWidgetsTitleIos)
        }
        .frame(width: 44, height: 44)
    }
}

private struct NitroRoomToolsMenuButtonRepresentable: UIViewRepresentable {
    let tapAction: () -> Void
    let longPressAction: (() -> Void)?
    let accessibilityLabel: String
    let accessibilityLongPressLabel: String
    
    func makeCoordinator() -> Coordinator {
        Coordinator(tapAction: tapAction, longPressAction: longPressAction)
    }
    
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.addTarget(context.coordinator, action: #selector(Coordinator.didTap), for: .touchUpInside)
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityTraits = .button
        
        let longPressGestureRecognizer = UILongPressGestureRecognizer(target: context.coordinator,
                                                                      action: #selector(Coordinator.didLongPress(_:)))
        longPressGestureRecognizer.minimumPressDuration = 0.5
        button.addGestureRecognizer(longPressGestureRecognizer)
        context.coordinator.update(button: button,
                                   tapAction: tapAction,
                                   longPressAction: longPressAction,
                                   accessibilityLongPressLabel: accessibilityLongPressLabel)
        return button
    }
    
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.update(button: button,
                                   tapAction: tapAction,
                                   longPressAction: longPressAction,
                                   accessibilityLongPressLabel: accessibilityLongPressLabel)
        button.accessibilityLabel = accessibilityLabel
    }
    
    final class Coordinator: NSObject {
        private var tapAction: () -> Void
        private var longPressAction: (() -> Void)?
        
        init(tapAction: @escaping () -> Void, longPressAction: (() -> Void)?) {
            self.tapAction = tapAction
            self.longPressAction = longPressAction
        }
        
        func update(button: UIButton,
                    tapAction: @escaping () -> Void,
                    longPressAction: (() -> Void)?,
                    accessibilityLongPressLabel: String) {
            self.tapAction = tapAction
            self.longPressAction = longPressAction
            button.accessibilityCustomActions = if longPressAction == nil {
                nil
            } else {
                [UIAccessibilityCustomAction(name: accessibilityLongPressLabel,
                                             target: self,
                                             selector: #selector(performAccessibilityLongPress))]
            }
        }
        
        @objc func didTap() {
            tapAction()
        }
        
        @objc func didLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
            guard gestureRecognizer.state == .began, let longPressAction else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            longPressAction()
        }
        
        @objc private func performAccessibilityLongPress() -> Bool {
            guard let longPressAction else { return false }
            longPressAction()
            return true
        }
    }
}

// MARK: - Previews

struct NitroRoomWidgetsScreen_Previews: PreviewProvider, TestablePreview {
    static let widgets = [
        NitroRoomWidget(id: "cockpit",
                        name: "Cockpit",
                        type: "com.nitrovery.c2m.cockpit",
                        url: URL(string: "https://pub-artifacts.nitrovery.com/cockpit")!,
                        waitForIframeLoad: false),
        NitroRoomWidget(id: "history",
                        name: "Thinking history",
                        type: "com.nitrovery.c2m.history",
                        url: URL(string: "https://artifacts.nitrovery.com/history")!,
                        waitForIframeLoad: false)
    ]
    
    static var previews: some View {
        Group {
            NitroRoomWidgetsScreen(context: context(destination: .list))
                .previewDisplayName("List")
            NitroRoomWidgetsScreen(context: context(destination: .loading(widgets[0])))
                .previewDisplayName("Loading")
            NitroRoomWidgetsScreen(context: context(destination: .widget(widgets[0], URL(string: "about:blank")!)))
                .previewDisplayName("Widget")
            NitroRoomWidgetsScreen(context: context(destination: .error(widgets[0])))
                .previewDisplayName("Error")
            panelPreview(layout: .compact)
                .previewDisplayName("Panel - Compact")
            panelPreview(layout: .regular)
                .previewDisplayName("Panel - Regular")
            panelPreview(layout: .expanded)
                .previewDisplayName("Panel - Expanded")
        }
    }
    
    private static func panelPreview(layout: NitroRoomWidgetPanelLayout) -> some View {
        VStack(spacing: 0) {
            NitroRoomWidgetPanel(controller: panelController(layout: layout), availableHeight: 700)
            Color.compound.bgCanvasDefault
        }
    }
    
    private static func panelController(layout: NitroRoomWidgetPanelLayout) -> NitroRoomWidgetPanelController {
        let controller = NitroRoomWidgetPanelController()
        controller.present(context: context(destination: .list))
        switch layout {
        case .compact:
            controller.collapse()
        case .regular:
            break
        case .expanded:
            controller.expand()
        }
        return controller
    }
    
    private static func context(destination: NitroRoomWidgetsScreenDestination) -> NitroRoomWidgetsScreenViewModel.Context {
        StateStoreViewModelV2<NitroRoomWidgetsScreenViewState, NitroRoomWidgetsScreenViewAction>(initialViewState: .init(widgets: widgets,
                                                                                                                         destination: destination)).context
    }
}
