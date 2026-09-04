//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

final class NitroGIFRecentStore {
    private static let maximumRecentGIFs = 12
    private static let keyPrefix = "nitroRecentGIFsV1."

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func recentGIFs(for userID: String) -> [NitroGIFResult] {
        guard let data = userDefaults.data(forKey: storageKey(for: userID)),
              let results = try? JSONDecoder().decode([NitroGIFResult].self, from: data) else {
            return []
        }
        return Array(results.prefix(Self.maximumRecentGIFs))
    }

    func record(_ result: NitroGIFResult, for userID: String) {
        var results = recentGIFs(for: userID).filter { $0.id != result.id }
        results.insert(result, at: 0)
        guard let data = try? JSONEncoder().encode(Array(results.prefix(Self.maximumRecentGIFs))) else { return }
        userDefaults.set(data, forKey: storageKey(for: userID))
    }

    private func storageKey(for userID: String) -> String {
        Self.keyPrefix + Data(userID.utf8).base64EncodedString()
    }
}
