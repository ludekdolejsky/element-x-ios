//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

struct DeveloperOptionsScreenViewModelTests {
    @Test
    func requestsTimelineDiagnosticActions() {
        let appSettings = AppSettings.volatile()
        let viewModel = DeveloperOptionsScreenViewModel(developerOptions: appSettings,
                                                        appHooks: AppHooks(),
                                                        clientProxy: nil)
        
        viewModel.context.send(viewAction: .forceReloadTimelineCells)
        #expect(appSettings.timelineCellReloadRequestID == 1)
        
        viewModel.context.send(viewAction: .rebuildTimelineView)
        #expect(appSettings.timelineViewRebuildRequestID == 1)
    }

    @Test
    func sendsSentryTestEvent() {
        let appSettings = AppSettings.volatile()
        appSettings.analyticsConsentState = .optedIn
        let viewModel = DeveloperOptionsScreenViewModel(developerOptions: appSettings,
                                                        appHooks: AppHooks(),
                                                        clientProxy: nil,
                                                        captureSentryTestEvent: { "test-event-id" })

        #expect(viewModel.context.viewState.isSentryEnabled)
        viewModel.context.send(viewAction: .sendSentryTestEvent)
        #expect(viewModel.context.viewState.sentryTestEventID == "test-event-id")
    }
}
