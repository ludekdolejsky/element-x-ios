//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroCatchUpScreenViewModelTests {
    @Test
    func decodesMinimalBackendJobWithDesktopDefaults() throws {
        let data = Data(#"{"job_id":"job-1","status":"queued"}"#.utf8)
        let job = try JSONDecoder().decode(NitroCatchUpJob.self, from: data)
        
        #expect(job.id == "job-1")
        #expect(job.stage == "queued")
        #expect(job.completedSteps == 0)
        #expect(job.totalSteps == 0)
        #expect(job.messageCount == 0)
        #expect(job.elapsedSeconds == 0)
    }
    
    @Test
    func startsFromLastReadInOverviewMode() throws {
        let service = NitroCatchUpServiceMock()
        let viewModel = makeViewModel(service: service)
        
        viewModel.context.send(viewAction: .start)
        
        let call = try #require(service.startCalls.first)
        #expect(call.roomID == "!room:example.org")
        #expect(call.roomName == "Nitro team")
        #expect(call.scope == .lastRead)
        #expect(call.mode == .overview)
    }
    
    @Test
    func startsFromSelectedDateInAttentionMode() throws {
        let service = NitroCatchUpServiceMock()
        let viewModel = makeViewModel(service: service)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        viewModel.context.startPoint = .date
        viewModel.context.date = date
        viewModel.context.mode = .attention
        
        viewModel.context.send(viewAction: .start)
        
        let call = try #require(service.startCalls.first)
        #expect(call.scope == .date(date))
        #expect(call.mode == .attention)
    }
    
    @Test
    func observesAndControlsRoomOperation() {
        let service = NitroCatchUpServiceMock()
        let viewModel = makeViewModel(service: service)
        let operation = NitroCatchUpOperation(id: "job-1",
                                              roomID: "!room:example.org",
                                              roomName: "Nitro team",
                                              mode: .overview,
                                              startedAt: Date(),
                                              state: .queued(messageCount: 12))
        
        service.operationsSubject.send([operation])
        viewModel.context.send(viewAction: .cancel)
        viewModel.context.send(viewAction: .dismissResult)
        
        #expect(viewModel.context.viewState.operation == operation)
        #expect(service.cancelledOperationIDs == ["job-1"])
        #expect(service.dismissedOperationIDs == ["job-1"])
        #expect(service.restoreCallCount == 1)
    }
    
    @Test
    func reportsStartFailure() {
        let service = NitroCatchUpServiceMock()
        service.startResult = .failure(.alreadyRunning)
        let viewModel = makeViewModel(service: service)
        
        viewModel.context.send(viewAction: .start)
        
        #expect(viewModel.context.alertInfo?.id == .requestFailed)
    }
    
    @Test
    func reportsActionFailureForCurrentOperation() {
        let service = NitroCatchUpServiceMock()
        let viewModel = makeViewModel(service: service)
        let operation = NitroCatchUpOperation(id: "job-1",
                                              roomID: "!room:example.org",
                                              roomName: "Nitro team",
                                              mode: .overview,
                                              startedAt: Date(),
                                              state: .queued(messageCount: 12))
        service.operationsSubject.send([operation])
        
        service.actionFailuresSubject.send("job-1")
        
        #expect(viewModel.context.alertInfo?.id == .requestFailed)
    }
    
    private func makeViewModel(service: NitroCatchUpServiceMock) -> NitroCatchUpScreenViewModel {
        NitroCatchUpScreenViewModel(roomID: "!room:example.org",
                                    roomName: "Nitro team",
                                    service: service)
    }
}
