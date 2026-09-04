//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroGIFRecentStoreTests {
    @Test
    func keepsTwelveDeduplicatedResultsPerUser() throws {
        let suiteName = "NitroGIFRecentStoreTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = NitroGIFRecentStore(userDefaults: userDefaults)

        for index in 0..<14 {
            store.record(makeResult(index), for: "@alice:example.org")
        }
        store.record(makeResult(5), for: "@alice:example.org")
        store.record(makeResult(99), for: "@bob:example.org")

        let aliceResults = store.recentGIFs(for: "@alice:example.org")
        #expect(aliceResults.count == 12)
        #expect(aliceResults.first?.id == "5")
        #expect(aliceResults.filter { $0.id == "5" }.count == 1)
        #expect(store.recentGIFs(for: "@bob:example.org") == [makeResult(99)])
    }

    private func makeResult(_ index: Int) -> NitroGIFResult {
        let url = URL(string: "https://media.example.org/\(index).gif")! // swiftlint:disable:this force_unwrapping
        return .init(id: String(index),
                     title: "GIF \(index)",
                     altText: "GIF \(index)",
                     thumbnailURL: url,
                     previewURL: url,
                     downloadURL: url)
    }
}
