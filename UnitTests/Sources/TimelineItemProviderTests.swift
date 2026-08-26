//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

struct TimelineItemProviderTests {
    @Test
    func marksInitialSnapshotOnlyAfterReset() async throws {
        let timeline = TimelineSDKMock()
        let listenerAddedSubject = PassthroughSubject<Void, Never>()
        var listener: TimelineListener?
        timeline.addListenerListenerClosure = { value in
            listener = value
            listenerAddedSubject.send(())
            return TaskHandleSDKMock()
        }
        let listenerAdded = deferFulfillment(listenerAddedSubject) { true }
        let provider = TimelineItemProvider(timeline: timeline,
                                            kind: .live,
                                            paginationStatePublisher: Just(.init(backward: .idle, forward: .endReached))
                                                .eraseToAnyPublisher())
        
        #expect(!provider.hasLoadedInitialSnapshot)
        try await listenerAdded.fulfill()
        let resetApplied = deferFulfillment(provider.updatePublisher) { _ in
            provider.hasLoadedInitialSnapshot
        }
        
        listener?.onUpdate(diff: [.reset(values: [])])
        try await resetApplied.fulfill()
        
        #expect(provider.hasLoadedInitialSnapshot)
        #expect(provider.itemProxies.isEmpty)
    }
}
