//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Sentry
import Synchronization

nonisolated enum NitroPerformance {
    // Sentry spans become invalid when the SDK restarts, so stale transactions must become no-ops.
    private struct State {
        var generation: UInt = 0
        var isReconfiguring = false
    }
    
    private static let state = Mutex(State())
    
    enum Outcome: String {
        case success
        case failure
        case cancelled
    }
    
    struct Transaction {
        private let span: any Sentry.Span
        private let generation: UInt
        
        fileprivate init(span: any Sentry.Span, generation: UInt) {
            self.span = span
            self.generation = generation
        }
        
        func setData(_ value: Int, key: String) {
            performIfCurrent { $0.setData(value: NSNumber(value: value), key: key) }
        }
        
        func setData(_ value: Bool, key: String) {
            performIfCurrent { $0.setData(value: NSNumber(value: value), key: key) }
        }
        
        func setTag(_ value: String, key: String) {
            performIfCurrent { $0.setTag(value: value, key: key) }
        }
        
        func finish(_ outcome: Outcome) {
            performIfCurrent { span in
                span.setTag(value: outcome.rawValue, key: "nitro.outcome")
                span.finish()
            }
        }
        
        private func performIfCurrent(_ operation: (any Sentry.Span) -> Void) {
            state.withLock { state in
                guard !state.isReconfiguring, state.generation == generation else { return }
                operation(span)
            }
        }
    }
    
    static func start(name: String, operation: String) -> Transaction {
        state.withLock { state in
            let context = TransactionContext(name: name,
                                             operation: operation,
                                             sampled: .yes,
                                             sampleRate: nil,
                                             sampleRand: nil)
            return .init(span: SentrySDK.startTransaction(transactionContext: context),
                         generation: state.generation)
        }
    }
    
    static func reconfigureSentry(_ operation: () -> Void) {
        state.withLock { state in
            state.generation &+= 1
            state.isReconfiguring = true
        }
        defer { state.withLock { $0.isReconfiguring = false } }
        operation()
    }
}
