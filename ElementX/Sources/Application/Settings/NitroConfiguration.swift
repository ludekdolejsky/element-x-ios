//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated enum NitroConfiguration {
    private static let defaultPushGatewayBaseURL: URL = "https://push.nitrovery.com"
    private static let defaultReminderBaseURL: URL = "https://matrix-bot.nitrovery.com"
    private static let defaultTranscriptionBaseURL: URL = "https://matrix-bot.nitrovery.com"
    
    static var isEnabled: Bool {
        InfoPlistReader.main.isNitroBuild
    }
    
    static var pushGatewayBaseURL: URL {
        InfoPlistReader.main.nitroPushGatewayBaseURL ?? defaultPushGatewayBaseURL
    }
    
    static var reminderBaseURL: URL {
        InfoPlistReader.main.nitroReminderBaseURL ?? defaultReminderBaseURL
    }
    
    static var transcriptionBaseURL: URL {
        InfoPlistReader.main.nitroTranscriptionBaseURL ?? defaultTranscriptionBaseURL
    }
}
