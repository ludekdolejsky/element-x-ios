//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

struct NitroCatchUpHistoryLoaderTests {
    private final class Source { }
    
    @Test
    func eventCacheInvalidatesWhenTimelineItemChanges() {
        var cache = NitroCatchUpEventCache<String>()
        let originalSource = Source()
        let updatedSource = Source()
        
        let original = cache.value(for: "$event", sourceIdentity: ObjectIdentifier(originalSource)) { "Original" }
        let cached = cache.value(for: "$event", sourceIdentity: ObjectIdentifier(originalSource)) { "Unexpected" }
        let updated = cache.value(for: "$event", sourceIdentity: ObjectIdentifier(updatedSource)) { "Updated" }
        
        #expect(original == "Original")
        #expect(cached == "Original")
        #expect(updated == "Updated")
    }
}
