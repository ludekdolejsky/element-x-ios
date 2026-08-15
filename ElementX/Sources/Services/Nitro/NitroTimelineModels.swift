//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

struct NitroTranscriptInfo: Equatable, Identifiable {
    let itemID: TimelineItemIdentifier
    let text: String
    
    var id: TimelineItemIdentifier {
        itemID
    }
}

enum NitroAudioTranscriptionRequest: Hashable {
    case currentVoiceMessage
    case timeline(itemID: TimelineItemIdentifier, sendToThread: Bool)
}
