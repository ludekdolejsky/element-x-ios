//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import Testing

struct NitroCatchUpServiceTests {
    @Test
    func cleansUpAmbiguousStartFailure() async throws {
        let api = NitroCatchUpAPIMock()
        api.startError = URLError(.timedOut)
        let service = makeService(api: api)
        let failed = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .failed(.transport) }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await failed.fulfill()
        
        let operation = try #require(service.operationsPublisher.value.first)
        #expect(api.cancelledJobIDs == [operation.id])
        #expect(api.cancellationTimeouts == [5])
    }
    
    @Test
    func reportsOversizedStartWithoutTryingToCancelServerJob() async throws {
        let api = NitroCatchUpAPIMock()
        api.startError = NitroCatchUpServiceError.rangeTooLarge
        let service = makeService(api: api)
        let failed = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .failed(.rangeTooLarge) }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await failed.fulfill()
        
        #expect(api.cancelledJobIDs.isEmpty)
    }
    
    @Test
    func retriesCancellationBeforeUpdatingLocalState() async throws {
        let api = NitroCatchUpAPIMock()
        api.cancelErrors = [URLError(.notConnectedToInternet), nil]
        let service = makeService(api: api, retryInterval: .zero)
        defer { service.stop() }
        let queued = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .queued(messageCount: 1) }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await queued.fulfill()
        let operationID = try #require(service.operationsPublisher.value.first?.id)
        let cancelled = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.id == operationID && $0.state == .cancelled }
        }
        
        service.cancel(operationID: operationID)
        try await cancelled.fulfill()
        
        #expect(api.cancelledJobIDs == [operationID, operationID])
    }
    
    @Test
    func doesNotRetryCancellationAfterPermanentHTTPFailure() async throws {
        let api = NitroCatchUpAPIMock()
        api.cancelErrors = [NitroCatchUpAPIError.httpStatus(400, message: nil)]
        let service = makeService(api: api, retryInterval: .zero)
        defer { service.stop() }
        let queued = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .queued(messageCount: 1) }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await queued.fulfill()
        let operationID = try #require(service.operationsPublisher.value.first?.id)
        let actionFailed = deferFulfillment(service.actionFailuresPublisher) { $0 == operationID }
        
        service.cancel(operationID: operationID)
        try await actionFailed.fulfill()
        
        #expect(api.cancelledJobIDs == [operationID])
        #expect(service.operationsPublisher.value.first?.state == .queued(messageCount: 1))
    }
    
    @Test
    func stopsRetryingCancellationAfterMaximumAttemptCount() async throws {
        let api = NitroCatchUpAPIMock()
        api.cancelErrors = (0..<5).map { _ in URLError(.notConnectedToInternet) as Error? }
        let service = makeService(api: api, retryInterval: .zero)
        defer { service.stop() }
        let queued = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .queued(messageCount: 1) }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await queued.fulfill()
        let operationID = try #require(service.operationsPublisher.value.first?.id)
        let actionFailed = deferFulfillment(service.actionFailuresPublisher) { $0 == operationID }
        
        service.cancel(operationID: operationID)
        try await actionFailed.fulfill()
        
        #expect(api.cancelledJobIDs == Array(repeating: operationID, count: 5))
        #expect(service.operationsPublisher.value.first?.state == .queued(messageCount: 1))
    }
    
    @Test
    func keepsPollingWhileServerIsCancelling() async throws {
        let api = NitroCatchUpAPIMock()
        api.cancelJobs = [job(status: "cancelling")]
        let service = makeService(api: api)
        defer { service.stop() }
        let queued = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .queued(messageCount: 1) }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await queued.fulfill()
        let operationID = try #require(service.operationsPublisher.value.first?.id)
        let cancelling = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains {
                $0.id == operationID && $0.state == .running(stage: "cancelling",
                                                             completedSteps: 0,
                                                             totalSteps: 0,
                                                             messageCount: 1)
            }
        }
        
        service.cancel(operationID: operationID)
        try await cancelling.fulfill()
        
        #expect(api.cancelledJobIDs == [operationID])
    }
    
    @Test
    func retriesDismissalBeforeRemovingLocalOperation() async throws {
        let api = NitroCatchUpAPIMock()
        api.startJob = job(status: "completed", summary: "Done")
        api.dismissErrors = [URLError(.notConnectedToInternet), nil]
        let service = makeService(api: api, retryInterval: .zero)
        let completed = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .completed(.init(summary: "Done", messageCount: 1, model: nil, promptVersion: nil)) }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await completed.fulfill()
        let operationID = try #require(service.operationsPublisher.value.first?.id)
        let dismissed = deferFulfillment(service.operationsPublisher) { $0.isEmpty }
        
        service.dismiss(operationID: operationID)
        try await dismissed.fulfill()
        
        #expect(api.dismissedJobIDs == [operationID, operationID])
    }
    
    @Test
    func keepsCompletedResultWhenDismissalFails() async throws {
        let api = NitroCatchUpAPIMock()
        api.startJob = job(status: "completed", summary: "Done")
        api.dismissErrors = [NitroCatchUpAPIError.httpStatus(400, message: nil)]
        let service = makeService(api: api, retryInterval: .zero)
        let completedState = NitroCatchUpOperationState.completed(.init(summary: "Done",
                                                                        messageCount: 1,
                                                                        model: nil,
                                                                        promptVersion: nil))
        let completed = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == completedState }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await completed.fulfill()
        let operationID = try #require(service.operationsPublisher.value.first?.id)
        let actionFailed = deferFulfillment(service.actionFailuresPublisher) { $0 == operationID }
        
        service.dismiss(operationID: operationID)
        try await actionFailed.fulfill()
        
        #expect(api.dismissedJobIDs == [operationID])
        #expect(service.operationsPublisher.value.first?.state == completedState)
    }
    
    @Test
    func failsPollingImmediatelyForPermanentHTTPFailure() async throws {
        let api = NitroCatchUpAPIMock()
        api.pollErrors = [NitroCatchUpAPIError.httpStatus(404, message: nil)]
        let service = makeService(api: api, pollInterval: .zero)
        let failed = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .failed(.transport) }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await failed.fulfill()
        
        #expect(api.polledJobIDs.count == 1)
    }
    
    @Test
    func refreshesAuthenticationOnceAfterUnauthorizedPoll() async throws {
        let api = NitroCatchUpAPIMock()
        api.pollErrors = [NitroCatchUpAPIError.httpStatus(401, message: nil)]
        api.pollJobs = [job(status: "cancelled")]
        let authenticationProvider = NitroCatchUpAuthenticationProviderMock()
        let service = makeService(api: api,
                                  authenticationProvider: authenticationProvider,
                                  pollInterval: .zero)
        let cancelled = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .cancelled }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await cancelled.fulfill()
        
        #expect(api.polledJobIDs.count == 2)
        #expect(authenticationProvider.authenticationCallsCount == 2)
    }
    
    @Test
    func reacquiresAuthenticationWhenDismissingRestoredCompletedJob() async throws {
        let api = NitroCatchUpAPIMock()
        api.restoredJobs = [job(status: "completed", summary: "Done")]
        let authenticationProvider = NitroCatchUpAuthenticationProviderMock()
        let service = makeService(api: api, authenticationProvider: authenticationProvider)
        let restored = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .completed(.init(summary: "Done", messageCount: 1, model: nil, promptVersion: nil)) }
        }
        
        service.restore()
        try await restored.fulfill()
        let operationID = try #require(service.operationsPublisher.value.first?.id)
        let dismissed = deferFulfillment(service.operationsPublisher) { $0.isEmpty }
        
        service.dismiss(operationID: operationID)
        try await dismissed.fulfill()
        
        #expect(authenticationProvider.authenticationCallsCount == 2)
    }
    
    @Test
    func stopPreventsSuspendedRestoreFromPublishingJobs() async throws {
        let api = NitroCatchUpAPIMock()
        api.shouldSuspendJobs = true
        api.restoredJobs = [job(status: "queued")]
        let service = makeService(api: api, pollInterval: .zero)
        let jobsRequested = deferFulfillment(api.jobsRequestedSubject) { _ in true }
        
        service.restore()
        try await jobsRequested.fulfill()
        service.stop()
        api.resumeJobs()
        await Task.yield()
        
        #expect(service.operationsPublisher.value.isEmpty)
        #expect(api.polledJobIDs.isEmpty)
    }
    
    @Test
    func exposesBackendFailureMessage() async throws {
        let api = NitroCatchUpAPIMock()
        api.startJob = job(status: "failed", error: "Daily catch up limit reached.")
        let service = makeService(api: api)
        let failed = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .failed(.backend("Daily catch up limit reached.")) }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await failed.fulfill()
    }
    
    @Test
    func exposesBackendHTTPErrorMessage() async throws {
        let api = NitroCatchUpAPIMock()
        api.startError = NitroCatchUpAPIError.httpStatus(429, message: "Daily catch up limit reached.")
        let service = makeService(api: api)
        let failed = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .failed(.backend("Daily catch up limit reached.")) }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await failed.fulfill()
    }
    
    @Test
    func preservesCompletedResultWhenPollingDeadlineExpires() async throws {
        let api = NitroCatchUpAPIMock()
        api.pollJobs = [job(status: "completed", summary: "Done")]
        let service = makeService(api: api, maximumPollingDuration: .zero)
        let completed = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .completed(.init(summary: "Done", messageCount: 1, model: nil, promptVersion: nil)) }
        }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await completed.fulfill()
        
        #expect(api.polledJobIDs.count == 1)
        #expect(api.cancelledJobIDs.isEmpty)
    }
    
    @Test
    func retriesRestoringJobsAfterTransientFailure() async throws {
        let api = NitroCatchUpAPIMock()
        api.jobsErrors = [URLError(.notConnectedToInternet), nil]
        api.restoredJobs = [job(status: "completed", summary: "Done")]
        let service = makeService(api: api, restoreRetryInterval: .zero)
        let restored = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.state == .completed(.init(summary: "Done", messageCount: 1, model: nil, promptVersion: nil)) }
        }
        
        service.restore()
        try await restored.fulfill()
        
        #expect(api.jobsRequestsCount == 2)
    }
    
    @Test
    func stopCancelsRunningOperations() async throws {
        let historyLoader = NitroCatchUpHistoryLoaderMock()
        historyLoader.shouldSuspend = true
        let api = NitroCatchUpAPIMock()
        let service = makeService(api: api, historyLoader: historyLoader)
        let started = deferFulfillment(historyLoader.startedSubject) { _ in true }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await started.fulfill()
        let cancelled = deferFulfillment(historyLoader.cancelledSubject) { _ in true }
        
        service.stop()
        try await cancelled.fulfill()
    }
    
    @Test
    func stopIgnoresDomainErrorProducedByCancellation() async throws {
        let historyLoader = NitroCatchUpHistoryLoaderMock()
        historyLoader.shouldSuspend = true
        historyLoader.cancellationError = NitroCatchUpServiceError.transport
        let api = NitroCatchUpAPIMock()
        let service = makeService(api: api, historyLoader: historyLoader)
        let started = deferFulfillment(historyLoader.startedSubject) { _ in true }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await started.fulfill()
        let cancelled = deferFulfillment(historyLoader.cancelledSubject) { _ in true }
        
        service.stop()
        try await cancelled.fulfill()
        
        #expect(service.operationsPublisher.value.allSatisfy { operation in
            if case .failed = operation.state {
                false
            } else {
                true
            }
        })
    }
    
    @Test
    func cancellationWhileReadingStopsLocalOperation() async throws {
        let historyLoader = NitroCatchUpHistoryLoaderMock()
        historyLoader.shouldSuspend = true
        let api = NitroCatchUpAPIMock()
        let authenticationProvider = NitroCatchUpAuthenticationProviderMock()
        let service = makeService(api: api,
                                  authenticationProvider: authenticationProvider,
                                  historyLoader: historyLoader)
        let started = deferFulfillment(historyLoader.startedSubject) { _ in true }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await started.fulfill()
        let operationID = try #require(service.operationsPublisher.value.first?.id)
        let operationCancelled = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.id == operationID && $0.state == .cancelled }
        }
        let loaderCancelled = deferFulfillment(historyLoader.cancelledSubject) { _ in true }
        
        service.cancel(operationID: operationID)
        try await operationCancelled.fulfill()
        try await loaderCancelled.fulfill()
        
        #expect(api.cancelledJobIDs.isEmpty)
        #expect(authenticationProvider.authenticationCallsCount == 0)
        service.dismiss(operationID: operationID)
        #expect(service.operationsPublisher.value.isEmpty)
        #expect(api.dismissedJobIDs.isEmpty)
        #expect(authenticationProvider.authenticationCallsCount == 0)
    }
    
    @Test
    func cancellationDuringStartCancelsCreatedServerJob() async throws {
        let api = NitroCatchUpAPIMock()
        api.shouldSuspendStart = true
        let service = makeService(api: api, pollInterval: .zero)
        defer { service.stop() }
        let startRequested = deferFulfillment(api.startRequestedSubject) { _ in true }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await startRequested.fulfill()
        let operationID = try #require(service.operationsPublisher.value.first?.id)
        let cancelled = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.id == operationID && $0.state == .cancelled }
        }
        
        service.cancel(operationID: operationID)
        #expect(api.cancelledJobIDs.isEmpty)
        api.resumeStart()
        try await cancelled.fulfill()
        
        #expect(api.cancelledJobIDs == [operationID])
    }
    
    @Test
    func cancellationDuringOversizedStartWinsWithoutServerCleanup() async throws {
        let api = NitroCatchUpAPIMock()
        api.shouldSuspendStart = true
        let service = makeService(api: api)
        let startRequested = deferFulfillment(api.startRequestedSubject) { _ in true }
        
        #expect(service.start(roomID: "!room:example.org",
                              roomName: "Nitro team",
                              scope: .lastRead,
                              mode: .overview).isSuccess)
        try await startRequested.fulfill()
        let operationID = try #require(service.operationsPublisher.value.first?.id)
        let cancelled = deferFulfillment(service.operationsPublisher) { operations in
            operations.contains { $0.id == operationID && $0.state == .cancelled }
        }
        
        service.cancel(operationID: operationID)
        api.resumeStart(throwing: NitroCatchUpServiceError.rangeTooLarge)
        try await cancelled.fulfill()
        
        #expect(api.cancelledJobIDs.isEmpty)
    }
    
    private func makeService(api: NitroCatchUpAPIMock,
                             authenticationProvider: NitroCatchUpAuthenticationProviderMock = .init(),
                             historyLoader: NitroCatchUpHistoryLoaderMock = .init(),
                             pollInterval: Duration = .seconds(5),
                             retryInterval: Duration = .seconds(5),
                             maximumPollingDuration: Duration = .seconds(25 * 60),
                             restoreRetryInterval: Duration = .seconds(5)) -> NitroCatchUpService {
        NitroCatchUpService(authenticationProvider: authenticationProvider,
                            historyLoader: historyLoader,
                            api: api,
                            pollInterval: pollInterval,
                            serverActionRetryInterval: retryInterval,
                            maximumPollingDuration: maximumPollingDuration,
                            restoreRetryInterval: restoreRetryInterval)
    }
    
    private func job(status: String, summary: String? = nil, error: String? = nil) -> NitroCatchUpJob {
        NitroCatchUpAPIMock.job(status: status, summary: summary, error: error)
    }
}

private final class NitroCatchUpAuthenticationProviderMock: NitroCatchUpAuthenticationProviderProtocol {
    private(set) var authenticationCallsCount = 0
    
    func authentication() async throws -> NitroCatchUpAuthentication {
        authenticationCallsCount += 1
        return .init(homeserverURL: "https://matrix.example.org",
                     openIDToken: .init(accessToken: "token", tokenType: "Bearer", matrixServerName: "example.org"))
    }
}

private final class NitroCatchUpHistoryLoaderMock: NitroCatchUpHistoryLoaderProtocol {
    let startedSubject = PassthroughSubject<Bool, Never>()
    let cancelledSubject = PassthroughSubject<Bool, Never>()
    var shouldSuspend = false
    var cancellationError: Error = CancellationError()
    
    func messages(roomID: String,
                  scope: NitroCatchUpScope,
                  progress: (NitroCatchUpProgress) -> Void) async throws -> [NitroCatchUpMessage] {
        startedSubject.send(true)
        if shouldSuspend {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                cancelledSubject.send(true)
                throw cancellationError
            }
        }
        return [.init(eventID: "$event",
                      sender: "Alice",
                      senderID: "@alice:example.org",
                      timestamp: "2026-08-25T12:00:00Z",
                      body: "Hello",
                      permalink: "https://matrix.to/#/!room:example.org/$event",
                      threadRootID: nil)]
    }
}

private final class NitroCatchUpAPIMock: NitroCatchUpAPIProtocol {
    let startRequestedSubject = PassthroughSubject<Bool, Never>()
    let jobsRequestedSubject = PassthroughSubject<Bool, Never>()
    var startJob = job(status: "queued")
    var startError: Error?
    var shouldSuspendStart = false
    var shouldSuspendJobs = false
    var jobsErrors = [Error?]()
    var cancelErrors = [Error?]()
    var cancelJobs = [NitroCatchUpJob]()
    var dismissErrors = [Error?]()
    var pollErrors = [Error?]()
    var pollJobs = [NitroCatchUpJob]()
    var restoredJobs = [NitroCatchUpJob]()
    private(set) var cancelledJobIDs = [String]()
    private(set) var cancellationTimeouts = [TimeInterval]()
    private(set) var dismissedJobIDs = [String]()
    private(set) var polledJobIDs = [String]()
    private(set) var jobsRequestsCount = 0
    private var suspendedStart: (requestID: String, continuation: CheckedContinuation<NitroCatchUpJob, Error>)?
    private var suspendedJobs: CheckedContinuation<[NitroCatchUpJob], Never>?
    
    func start(requestID: String,
               roomID: String,
               roomName: String,
               mode: NitroCatchUpMode,
               messages: [NitroCatchUpMessage],
               authentication: NitroCatchUpAuthentication) async throws -> NitroCatchUpJob {
        if shouldSuspendStart {
            startRequestedSubject.send(true)
            return try await withCheckedThrowingContinuation { continuation in
                suspendedStart = (requestID, continuation)
            }
        }
        if let startError {
            throw startError
        }
        return Self.job(id: requestID,
                        status: startJob.status,
                        summary: startJob.summary,
                        error: startJob.error)
    }
    
    func resumeStart(throwing error: Error? = nil) {
        guard let suspendedStart else { return }
        self.suspendedStart = nil
        if let error {
            suspendedStart.continuation.resume(throwing: error)
        } else {
            suspendedStart.continuation.resume(returning: Self.job(id: suspendedStart.requestID,
                                                                   status: startJob.status,
                                                                   summary: startJob.summary,
                                                                   error: startJob.error))
        }
    }
    
    func poll(jobID: String, authentication: NitroCatchUpAuthentication) async throws -> NitroCatchUpJob {
        polledJobIDs.append(jobID)
        if !pollErrors.isEmpty, let error = pollErrors.removeFirst() {
            throw error
        }
        if !pollJobs.isEmpty {
            let job = pollJobs.removeFirst()
            return Self.job(id: jobID, status: job.status, summary: job.summary, error: job.error)
        }
        return Self.job(id: jobID, status: startJob.status, summary: startJob.summary)
    }
    
    func jobs(authentication: NitroCatchUpAuthentication) async throws -> [NitroCatchUpJob] {
        jobsRequestsCount += 1
        if shouldSuspendJobs {
            jobsRequestedSubject.send(true)
            return await withCheckedContinuation { continuation in
                suspendedJobs = continuation
            }
        }
        if !jobsErrors.isEmpty, let error = jobsErrors.removeFirst() {
            throw error
        }
        return restoredJobs
    }
    
    func resumeJobs() {
        guard let suspendedJobs else { return }
        self.suspendedJobs = nil
        suspendedJobs.resume(returning: restoredJobs)
    }
    
    func cancel(jobID: String,
                authentication: NitroCatchUpAuthentication,
                timeoutInterval: TimeInterval) async throws -> NitroCatchUpJob {
        cancelledJobIDs.append(jobID)
        cancellationTimeouts.append(timeoutInterval)
        if !cancelErrors.isEmpty, let error = cancelErrors.removeFirst() {
            throw error
        }
        if !cancelJobs.isEmpty {
            let job = cancelJobs.removeFirst()
            return Self.job(id: jobID, status: job.status, summary: job.summary, error: job.error)
        }
        return Self.job(id: jobID, status: "cancelled")
    }
    
    func dismiss(jobID: String, authentication: NitroCatchUpAuthentication) async throws {
        dismissedJobIDs.append(jobID)
        if !dismissErrors.isEmpty, let error = dismissErrors.removeFirst() {
            throw error
        }
    }
    
    static func job(id: String = "job", status: String, summary: String? = nil, error: String? = nil) -> NitroCatchUpJob {
        .init(id: id,
              status: status,
              messageCount: 1,
              summary: summary,
              error: error,
              roomID: "!room:example.org",
              roomName: "Nitro team",
              mode: .overview)
    }
}

private extension Result where Success == Void, Failure == NitroCatchUpServiceError {
    var isSuccess: Bool {
        if case .success = self {
            true
        } else {
            false
        }
    }
}
