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
        case .widget(_, let url):
            NitroRoomWidgetWebView(url: url, context: context)
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
    let url: URL
    let context: NitroRoomWidgetsScreenViewModel.Context
    
    func makeCoordinator() -> Coordinator {
        Coordinator(context: context, allowedURL: url)
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
        private static let handlerName = "widgetAction"
        private let context: NitroRoomWidgetsScreenViewModel.Context
        private let allowedURL: URL
        private var loadedURL: URL?
        let webView: WKWebView
        
        init(context: NitroRoomWidgetsScreenViewModel.Context, allowedURL: URL) {
            self.context = context
            self.allowedURL = allowedURL
            
            let userContentController = WKUserContentController()
            let script = """
            window.addEventListener('message', function(event) {
                if (event.source !== window || event.origin !== window.location.origin) {
                    return;
                }
                const data = event.data;
                if ((data.response && data.api === 'toWidget') || (!data.response && data.api === 'fromWidget')) {
                    window.webkit.messageHandlers.\(Self.handlerName).postMessage(JSON.stringify(data));
                }
            }, false);
            """
            userContentController.addUserScript(.init(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            
            let configuration = WKWebViewConfiguration()
            configuration.userContentController = userContentController
            configuration.applicationNameForUserAgent = InfoPlistReader.main.bundleDisplayName
            webView = WKWebView(frame: .zero, configuration: configuration)
            
            super.init()
            
            userContentController.add(NitroRoomWidgetScriptMessageHandler(self), name: Self.handlerName)
            webView.navigationDelegate = self
            webView.allowsLinkPreview = true
            webView.isInspectable = true
            webView.isOpaque = false
            webView.backgroundColor = .compound.bgCanvasDefault
            webView.scrollView.backgroundColor = .compound.bgCanvasDefault
        }
        
        func stop() {
            context.send(viewAction: .webViewStopped)
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        }
        
        func load(_ url: URL) {
            guard loadedURL != url else { return }
            loadedURL = url
            webView.load(URLRequest(url: url))
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.handlerName,
                  message.frameInfo.isMainFrame,
                  isAllowed(message.frameInfo.securityOrigin),
                  let body = message.body as? String else {
                return
            }
            context.send(viewAction: .widgetMessage(body, javaScriptEvaluator: evaluateJavaScript))
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                context.send(viewAction: .webViewFailed)
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
                context.send(viewAction: .webViewFailed)
            }
            return .cancel
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            guard navigationResponse.isForMainFrame else { return .allow }
            guard let response = navigationResponse.response as? HTTPURLResponse,
                  (200..<400).contains(response.statusCode) else {
                context.send(viewAction: .webViewFailed)
                return .cancel
            }
            return .allow
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            context.send(viewAction: .webViewStopped)
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url, NitroRoomWidgetOrigin(url: allowedURL)?.matches(url) == true else {
                context.send(viewAction: .webViewFailed)
                return
            }
            context.send(viewAction: .webViewReady(evaluateJavaScript))
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            handleNavigationFailure(error)
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            handleNavigationFailure(error)
        }
        
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            context.send(viewAction: .webViewFailed)
        }
        
        private func isAllowed(_ securityOrigin: WKSecurityOrigin) -> Bool {
            guard let allowedOrigin = NitroRoomWidgetOrigin(url: allowedURL) else { return false }
            return allowedOrigin.matches(scheme: securityOrigin.protocol,
                                         host: securityOrigin.host,
                                         port: securityOrigin.port)
        }
        
        private func handleNavigationFailure(_ error: any Error) {
            let error = error as NSError
            guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
            context.send(viewAction: .webViewFailed)
        }
        
        private func evaluateJavaScript(_ script: String) async throws {
            try await withCheckedThrowingContinuation { [weak self] continuation in
                guard let self else {
                    continuation.resume()
                    return
                }
                webView.evaluateJavaScript(script) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
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
