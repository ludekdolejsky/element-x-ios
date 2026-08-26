//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated enum NitroCatchUpScope: Equatable, Sendable {
    case lastRead
    case date(Date)
}

nonisolated enum NitroCatchUpMode: String, CaseIterable, Identifiable, Sendable {
    case overview
    case attention
    
    var id: Self {
        self
    }
}

nonisolated struct NitroCatchUpResult: Equatable, Sendable {
    let summary: String
    let messageCount: Int
    let model: String?
    let promptVersion: String?
}

nonisolated struct NitroCatchUpProgress: Equatable, Sendable {
    let scannedEventCount: Int
    let messageCount: Int
}

nonisolated enum NitroCatchUpOperationState: Equatable, Sendable {
    case reading(NitroCatchUpProgress)
    case queued(messageCount: Int)
    case running(stage: String, completedSteps: Int, totalSteps: Int, messageCount: Int)
    case completed(NitroCatchUpResult)
    case failed(NitroCatchUpServiceError)
    case cancelled
    
    var isRunning: Bool {
        switch self {
        case .reading, .queued, .running:
            true
        case .completed, .failed, .cancelled:
            false
        }
    }
}

nonisolated struct NitroCatchUpOperation: Equatable, Identifiable, Sendable {
    let id: String
    let roomID: String
    let roomName: String
    let mode: NitroCatchUpMode
    let startedAt: Date
    var state: NitroCatchUpOperationState
}

nonisolated enum NitroCatchUpServiceError: Error, Equatable, Sendable {
    case alreadyRunning
    case backend(String)
    case invalidResponse
    case noReadMarker
    case rangeTooLarge
    case roomUnavailable
    case transport
}
