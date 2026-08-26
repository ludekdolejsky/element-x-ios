//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK

protocol NitroCatchUpAuthenticationProviderProtocol {
    func authentication() async throws -> NitroCatchUpAuthentication
}

private struct NitroCatchUpAuthenticationProvider: NitroCatchUpAuthenticationProviderProtocol {
    let client: ClientProtocol
    
    func authentication() async throws -> NitroCatchUpAuthentication {
        let session = try client.session()
        let token = try await client.requestOpenidToken()
        return .init(homeserverURL: session.homeserverUrl,
                     openIDToken: .init(accessToken: token.accessToken,
                                        tokenType: token.tokenType,
                                        matrixServerName: token.matrixServerName))
    }
}

final class NitroCatchUpService: NitroCatchUpServiceProtocol {
    private struct TrackedTask {
        let id: UUID
        let task: Task<Void, Never>
    }
    
    private final class OperationRuntime {
        var operation: NitroCatchUpOperation
        var operationTask: TrackedTask?
        var serverActionTask: TrackedTask?
        var authentication: NitroCatchUpAuthentication?
        var isStarting = false
        var hasPendingCancellation = false
        var existsOnServer = false
        
        init(operation: NitroCatchUpOperation) {
            self.operation = operation
        }
    }
    
    private enum ServerAction: Equatable {
        case cancel
        case dismiss
    }
    
    private enum ServerActionResult {
        case completed
        case failed
        case retry
        case cancelled
    }
    
    private static let pollInterval: Duration = .seconds(5)
    private static let maximumPollInterval: Duration = .seconds(30)
    private static let cancellationTimeout: TimeInterval = 5
    private static let defaultServerActionRetryInterval: Duration = .seconds(5)
    private static let maximumServerActionRetryInterval: Duration = .seconds(30)
    private static let maximumServerActionAttemptCount = 5
    private static let maximumRestoreAttemptCount = 5
    
    private let authenticationProvider: NitroCatchUpAuthenticationProviderProtocol
    private let historyLoader: NitroCatchUpHistoryLoaderProtocol
    private let api: NitroCatchUpAPIProtocol
    private let pollInterval: Duration
    private let serverActionRetryInterval: Duration
    private let restoreRetryInterval: Duration
    private let operationsSubject = CurrentValueSubject<[NitroCatchUpOperation], Never>([])
    private let actionFailuresSubject = PassthroughSubject<String, Never>()
    private var operationRuntimes = [String: OperationRuntime]()
    private var restoreTask: TrackedTask?
    
    var operationsPublisher: CurrentValuePublisher<[NitroCatchUpOperation], Never> {
        operationsSubject.asCurrentValuePublisher()
    }
    
    var actionFailuresPublisher: AnyPublisher<String, Never> {
        actionFailuresSubject.eraseToAnyPublisher()
    }
    
    init(client: ClientProtocol, baseURL: URL, urlSession: URLSession = .shared) {
        authenticationProvider = NitroCatchUpAuthenticationProvider(client: client)
        historyLoader = NitroCatchUpHistoryLoader(client: client)
        api = NitroCatchUpAPI(baseURL: baseURL, urlSession: urlSession)
        pollInterval = Self.pollInterval
        serverActionRetryInterval = Self.defaultServerActionRetryInterval
        restoreRetryInterval = Self.defaultServerActionRetryInterval
    }
    
    init(authenticationProvider: NitroCatchUpAuthenticationProviderProtocol,
         historyLoader: NitroCatchUpHistoryLoaderProtocol,
         api: NitroCatchUpAPIProtocol,
         pollInterval: Duration = NitroCatchUpService.pollInterval,
         serverActionRetryInterval: Duration = NitroCatchUpService.defaultServerActionRetryInterval,
         restoreRetryInterval: Duration = NitroCatchUpService.defaultServerActionRetryInterval) {
        self.authenticationProvider = authenticationProvider
        self.historyLoader = historyLoader
        self.api = api
        self.pollInterval = pollInterval
        self.serverActionRetryInterval = serverActionRetryInterval
        self.restoreRetryInterval = restoreRetryInterval
    }
    
    func start(roomID: String,
               roomName: String,
               scope: NitroCatchUpScope,
               mode: NitroCatchUpMode) -> Result<Void, NitroCatchUpServiceError> {
        guard !operationRuntimes.values.contains(where: { $0.operation.roomID == roomID && $0.operation.state.isRunning }) else {
            return .failure(.alreadyRunning)
        }
        let operationID = UUID().uuidString
        setOperation(.init(id: operationID,
                           roomID: roomID,
                           roomName: roomName,
                           mode: mode,
                           startedAt: Date(),
                           state: .reading(.init(scannedEventCount: 0, messageCount: 0))))
        startOperationTask(operationID: operationID, name: "Nitro catch up \(operationID)") { service in
            await service.run(operationID: operationID, roomID: roomID, roomName: roomName, scope: scope, mode: mode)
        }
        return .success(())
    }
    
    func restore() {
        guard restoreTask == nil else { return }
        let taskID = UUID()
        let task = Task(name: "Restore Nitro catch up jobs") { [weak self] in
            await self?.restoreJobs()
            self?.finishRestoreTask(taskID: taskID)
        }
        restoreTask = .init(id: taskID, task: task)
    }
    
    func stop() {
        restoreTask?.task.cancel()
        restoreTask = nil
        operationRuntimes.values.forEach { runtime in
            runtime.operationTask?.task.cancel()
            runtime.serverActionTask?.task.cancel()
        }
        operationRuntimes.removeAll()
        publishOperations()
    }
    
    func cancel(operationID: String) {
        guard let runtime = operationRuntimes[operationID] else { return }
        if case .reading = runtime.operation.state {
            if runtime.isStarting {
                runtime.hasPendingCancellation = true
            } else {
                runtime.operationTask?.task.cancel()
                updateOperation(operationID) { $0.state = .cancelled }
            }
            return
        }
        startServerActionTask(operationID: operationID, action: .cancel)
    }
    
    func dismiss(operationID: String) {
        guard let runtime = operationRuntimes[operationID] else { return }
        guard runtime.existsOnServer else {
            removeOperation(operationID)
            return
        }
        startServerActionTask(operationID: operationID, action: .dismiss)
    }
    
    private func run(operationID: String,
                     roomID: String,
                     roomName: String,
                     scope: NitroCatchUpScope,
                     mode: NitroCatchUpMode) async {
        do {
            let messages = try await historyLoader.messages(roomID: roomID, scope: scope) { [weak self] progress in
                guard case .reading = self?.operationRuntimes[operationID]?.operation.state else { return }
                self?.updateOperation(operationID) { $0.state = .reading(progress) }
            }
            try Task.checkCancellation()
            if messages.isEmpty {
                updateOperation(operationID) {
                    $0.state = .completed(.init(summary: UntranslatedL10n.screenNitroCatchUpAlreadyCaughtUpIos,
                                                messageCount: 0,
                                                model: nil,
                                                promptVersion: nil))
                }
                return
            }
            let authentication = try await authentication(for: operationID)
            guard let job = try await startJob(operationID: operationID,
                                               roomID: roomID,
                                               roomName: roomName,
                                               mode: mode,
                                               messages: messages,
                                               authentication: authentication) else {
                return
            }
            guard let runtime = operationRuntimes[operationID] else { return }
            if runtime.hasPendingCancellation {
                runtime.hasPendingCancellation = false
                apply(job, fallbackRoomID: roomID, fallbackRoomName: roomName, fallbackMode: mode)
                startServerActionTask(operationID: operationID, action: .cancel)
                await poll(jobID: operationID,
                           roomID: roomID,
                           roomName: roomName,
                           mode: mode,
                           authentication: authentication)
                return
            }
            try Task.checkCancellation()
            apply(job, fallbackRoomID: roomID, fallbackRoomName: roomName, fallbackMode: mode)
            await poll(jobID: operationID,
                       roomID: roomID,
                       roomName: roomName,
                       mode: mode,
                       authentication: authentication)
        } catch {
            handleRunError(error, operationID: operationID, roomID: roomID)
        }
    }
    
    private func startJob(operationID: String,
                          roomID: String,
                          roomName: String,
                          mode: NitroCatchUpMode,
                          messages: [NitroCatchUpMessage],
                          authentication: NitroCatchUpAuthentication) async throws -> NitroCatchUpJob? {
        guard let runtime = operationRuntimes[operationID] else { return nil }
        runtime.isStarting = true
        defer { runtime.isStarting = false }
        do {
            let job = try await api.start(requestID: operationID,
                                          roomID: roomID,
                                          roomName: roomName,
                                          mode: mode,
                                          messages: messages,
                                          authentication: authentication)
            runtime.existsOnServer = true
            return job
        } catch is CancellationError {
            guard runtime.hasPendingCancellation else { throw CancellationError() }
            runtime.hasPendingCancellation = false
            await cancelAmbiguousStart(operationID: operationID, authentication: authentication)
            updateOperation(operationID) { $0.state = .cancelled }
            return nil
        } catch NitroCatchUpServiceError.rangeTooLarge {
            guard runtime.hasPendingCancellation else { throw NitroCatchUpServiceError.rangeTooLarge }
            runtime.hasPendingCancellation = false
            updateOperation(operationID) { $0.state = .cancelled }
            return nil
        } catch {
            guard runtime.hasPendingCancellation else { throw error }
            runtime.hasPendingCancellation = false
            await cancelAmbiguousStart(operationID: operationID, authentication: authentication)
            updateOperation(operationID) { $0.state = .cancelled }
            return nil
        }
    }
    
    private func handleRunError(_ error: Error, operationID: String, roomID: String) {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        if let error = error as? NitroCatchUpServiceError {
            updateOperation(operationID) { $0.state = .failed(error) }
        } else if case let NitroCatchUpAPIError.httpStatus(_, message) = error,
                  let message,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateOperation(operationID) { $0.state = .failed(.backend(message)) }
        } else {
            MXLog.error("Catch me up failed for \(roomID) with error: \(error)")
            updateOperation(operationID) { $0.state = .failed(.transport) }
        }
    }
    
    private func poll(jobID: String,
                      roomID: String,
                      roomName: String,
                      mode: NitroCatchUpMode,
                      authentication initialAuthentication: NitroCatchUpAuthentication) async {
        var failureCount = 0
        var authentication = initialAuthentication
        var hasRefreshedAuthentication = false
        while !Task.isCancelled {
            guard operationRuntimes[jobID]?.operation.state.isRunning == true else { return }
            let multiplier = 1 << min(failureCount, 3)
            let delay = min(pollInterval * multiplier, Self.maximumPollInterval)
            do {
                try await Task.sleep(for: delay)
                let job = try await api.poll(jobID: jobID, authentication: authentication)
                try Task.checkCancellation()
                failureCount = 0
                apply(job, fallbackRoomID: roomID, fallbackRoomName: roomName, fallbackMode: mode)
                if job.isFinished {
                    return
                }
            } catch is CancellationError {
                return
            } catch NitroCatchUpAPIError.httpStatus(401, _) where !hasRefreshedAuthentication {
                guard !Task.isCancelled else { return }
                operationRuntimes[jobID]?.authentication = nil
                do {
                    authentication = try await self.authentication(for: jobID)
                    hasRefreshedAuthentication = true
                    failureCount = 0
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    failureCount += 1
                    MXLog.warning("Unable to refresh Catch me up authentication for \(jobID)")
                }
            } catch NitroCatchUpAPIError.httpStatus(let status, _) where !Self.isRetryableHTTPStatus(status) {
                guard !Task.isCancelled else { return }
                MXLog.warning("Catch me up polling failed with HTTP \(status) for \(jobID)")
                updateOperation(jobID) { $0.state = .failed(.transport) }
                return
            } catch {
                guard !Task.isCancelled else { return }
                failureCount += 1
                MXLog.warning("Catch me up polling interrupted for \(jobID)")
            }
        }
    }
    
    private func restoreJobs() async {
        var failureCount = 0
        while !Task.isCancelled, failureCount < Self.maximumRestoreAttemptCount {
            do {
                let authentication = try await makeAuthentication()
                try Task.checkCancellation()
                let jobs = try await api.jobs(authentication: authentication)
                try Task.checkCancellation()
                for job in jobs {
                    guard let roomID = job.roomID, let roomName = job.roomName, let mode = job.mode else { continue }
                    apply(job, fallbackRoomID: roomID, fallbackRoomName: roomName, fallbackMode: mode)
                    guard let runtime = operationRuntimes[job.id] else { continue }
                    runtime.existsOnServer = true
                    guard !job.isFinished else { continue }
                    runtime.authentication = authentication
                    if runtime.operationTask == nil {
                        startOperationTask(operationID: job.id, name: "Resume Nitro catch up \(job.id)") { service in
                            await service.poll(jobID: job.id,
                                               roomID: roomID,
                                               roomName: roomName,
                                               mode: mode,
                                               authentication: authentication)
                        }
                    }
                }
                return
            } catch is CancellationError {
                return
            } catch {
                failureCount += 1
                guard failureCount < Self.maximumRestoreAttemptCount else {
                    MXLog.warning("Unable to restore Catch me up jobs")
                    return
                }
                let multiplier = 1 << min(failureCount - 1, 3)
                let delay = min(restoreRetryInterval * multiplier, Self.maximumServerActionRetryInterval)
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }
    
    private func authentication(for operationID: String) async throws -> NitroCatchUpAuthentication {
        if let authentication = operationRuntimes[operationID]?.authentication {
            return authentication
        }
        let authentication = try await makeAuthentication()
        try Task.checkCancellation()
        operationRuntimes[operationID]?.authentication = authentication
        return authentication
    }
    
    private func cancelAmbiguousStart(operationID: String, authentication: NitroCatchUpAuthentication) async {
        do {
            _ = try await api.cancel(jobID: operationID,
                                     authentication: authentication,
                                     timeoutInterval: Self.cancellationTimeout)
        } catch is CancellationError {
            return
        } catch {
            MXLog.warning("Unable to clean up ambiguous Catch me up start \(operationID)")
        }
    }
    
    private func startOperationTask(operationID: String,
                                    name: String,
                                    operation: @escaping (NitroCatchUpService) async -> Void) {
        guard let runtime = operationRuntimes[operationID] else { return }
        runtime.operationTask?.task.cancel()
        let taskID = UUID()
        let task = Task(name: name) { [weak self] in
            guard let self else { return }
            await operation(self)
            finishOperationTask(operationID: operationID, taskID: taskID)
        }
        runtime.operationTask = .init(id: taskID, task: task)
    }
    
    private func startServerActionTask(operationID: String, action: ServerAction) {
        guard let runtime = operationRuntimes[operationID] else { return }
        runtime.serverActionTask?.task.cancel()
        let taskID = UUID()
        let retryInterval = serverActionRetryInterval
        let name = switch action {
        case .cancel: "Cancel Nitro catch up \(operationID)"
        case .dismiss: "Dismiss Nitro catch up \(operationID)"
        }
        let task = Task(name: name) { [weak self] in
            var failureCount = 0
            while !Task.isCancelled, failureCount < Self.maximumServerActionAttemptCount {
                guard let result = await self?.performServerAction(action, operationID: operationID) else { return }
                switch result {
                case .completed, .cancelled:
                    self?.finishServerActionTask(operationID: operationID, taskID: taskID)
                    return
                case .failed:
                    self?.actionFailuresSubject.send(operationID)
                    self?.finishServerActionTask(operationID: operationID, taskID: taskID)
                    return
                case .retry:
                    failureCount += 1
                    guard failureCount < Self.maximumServerActionAttemptCount else {
                        self?.actionFailuresSubject.send(operationID)
                        self?.finishServerActionTask(operationID: operationID, taskID: taskID)
                        return
                    }
                    let multiplier = 1 << min(failureCount - 1, 3)
                    let delay = min(retryInterval * multiplier, Self.maximumServerActionRetryInterval)
                    try? await Task.sleep(for: delay)
                }
            }
            self?.finishServerActionTask(operationID: operationID, taskID: taskID)
        }
        runtime.serverActionTask = .init(id: taskID, task: task)
    }
    
    private func performServerAction(_ action: ServerAction, operationID: String) async -> ServerActionResult {
        do {
            let authentication = try await authentication(for: operationID)
            switch action {
            case .cancel:
                guard let operation = operationRuntimes[operationID]?.operation else { return .completed }
                let job = try await api.cancel(jobID: operationID, authentication: authentication)
                apply(job,
                      fallbackRoomID: operation.roomID,
                      fallbackRoomName: operation.roomName,
                      fallbackMode: operation.mode)
            case .dismiss:
                try await api.dismiss(jobID: operationID, authentication: authentication)
                removeOperation(operationID)
            }
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch NitroCatchUpAPIError.httpStatus(404, _) where action == .dismiss {
            removeOperation(operationID)
            return .completed
        } catch NitroCatchUpAPIError.httpStatus(let status, _) where !Self.isRetryableHTTPStatus(status) {
            MXLog.warning("Catch me up server action failed with HTTP \(status) for \(operationID)")
            return .failed
        } catch {
            switch action {
            case .cancel:
                MXLog.warning("Retrying cancellation of Catch me up job \(operationID)")
            case .dismiss:
                MXLog.warning("Retrying dismissal of Catch me up job \(operationID)")
            }
            return .retry
        }
    }
    
    private static func isRetryableHTTPStatus(_ status: Int) -> Bool {
        status == 408 || status == 429 || status >= 500
    }
    
    private func finishOperationTask(operationID: String, taskID: UUID) {
        guard let runtime = operationRuntimes[operationID], runtime.operationTask?.id == taskID else { return }
        runtime.operationTask = nil
        if !runtime.operation.state.isRunning {
            runtime.authentication = nil
        }
    }
    
    private func finishRestoreTask(taskID: UUID) {
        guard restoreTask?.id == taskID else { return }
        restoreTask = nil
    }
    
    private func finishServerActionTask(operationID: String, taskID: UUID) {
        guard let runtime = operationRuntimes[operationID], runtime.serverActionTask?.id == taskID else { return }
        runtime.serverActionTask = nil
        if runtime.operationTask == nil, !runtime.operation.state.isRunning {
            runtime.authentication = nil
        }
    }
    
    private func removeOperation(_ operationID: String) {
        operationRuntimes[operationID] = nil
        publishOperations()
    }
    
    private func makeAuthentication() async throws -> NitroCatchUpAuthentication {
        try await authenticationProvider.authentication()
    }
    
    private func apply(_ job: NitroCatchUpJob,
                       fallbackRoomID: String,
                       fallbackRoomName: String,
                       fallbackMode: NitroCatchUpMode) {
        let state: NitroCatchUpOperationState = switch job.status {
        case "queued":
            .queued(messageCount: job.messageCount)
        case "running", "cancelling":
            .running(stage: job.stage,
                     completedSteps: job.completedSteps,
                     totalSteps: job.totalSteps,
                     messageCount: job.messageCount)
        case "completed":
            if let summary = job.summary {
                .completed(.init(summary: summary,
                                 messageCount: job.messageCount,
                                 model: job.model,
                                 promptVersion: job.promptVersion))
            } else {
                .failed(.invalidResponse)
            }
        case "cancelled":
            .cancelled
        case "failed", "interrupted":
            if let error = job.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                .failed(.backend(error))
            } else {
                .failed(.transport)
            }
        default:
            .failed(.transport)
        }
        let operation = NitroCatchUpOperation(id: job.id,
                                              roomID: job.roomID ?? fallbackRoomID,
                                              roomName: job.roomName ?? fallbackRoomName,
                                              mode: job.mode ?? fallbackMode,
                                              startedAt: operationRuntimes[job.id]?.operation.startedAt ?? Date(),
                                              state: state)
        setOperation(operation)
    }
    
    private func setOperation(_ operation: NitroCatchUpOperation) {
        if let runtime = operationRuntimes[operation.id] {
            runtime.operation = operation
        } else {
            operationRuntimes[operation.id] = .init(operation: operation)
        }
        publishOperations()
    }
    
    private func updateOperation(_ operationID: String, update: (inout NitroCatchUpOperation) -> Void) {
        guard let runtime = operationRuntimes[operationID] else { return }
        var operation = runtime.operation
        update(&operation)
        setOperation(operation)
    }
    
    private func publishOperations() {
        operationsSubject.send(operationRuntimes.values.map(\.operation).sorted { $0.startedAt > $1.startedAt })
    }
}
