//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated struct NitroOpenIDToken: Equatable, Sendable {
    let accessToken: String
    let tokenType: String
    let matrixServerName: String
}

nonisolated enum NitroTranscriptionError: Error, Equatable, Sendable {
    case cancelled
    case emptyTranscript
    case httpError(statusCode: Int)
    case invalidResponse
    case transport
}

// sourcery: AutoMockable
nonisolated protocol NitroTranscriptionServiceProtocol: Sendable {
    func transcribeAudio(at fileURL: URL,
                         filename: String,
                         contentType: String,
                         homeserverURL: URL,
                         openIDToken: NitroOpenIDToken) async -> Result<String, NitroTranscriptionError>
}
