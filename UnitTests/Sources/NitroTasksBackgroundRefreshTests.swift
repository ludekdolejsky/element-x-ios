//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

struct NitroTasksBackgroundRefreshTests {
    @Test
    func targetedRefreshDoesNotShowTheGlobalLoadingIndicator() async throws {
        let service = NitroTaskServiceMock()
        let viewModel = NitroTasksScreenViewModel(taskService: service)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.hasLoaded)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        
        let roomID = "!changed:example.org"
        let (refreshes, refreshContinuation) = AsyncStream.makeStream(of: Set<String>.self)
        var resultContinuation: CheckedContinuation<Result<NitroTaskList, NitroTaskServiceError>, Never>?
        service.refreshTasksClosure = { roomIDs in
            refreshContinuation.yield(roomIDs)
            return await withCheckedContinuation { resultContinuation = $0 }
        }
        
        viewModel.refresh(roomIDs: [roomID])
        for await roomIDs in refreshes {
            #expect(roomIDs == [roomID])
            break
        }
        
        #expect(!viewModel.context.viewState.isLoading)
        resultContinuation?.resume(returning: .success(.init(tasks: [], unavailableRoomCount: 0)))
        refreshContinuation.finish()
    }
}
