//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated enum NitroConfiguration {
    private static let defaultPushGatewayBaseURL: URL = "https://matrix.org"
    private static let defaultNitroPushGatewayBaseURL: URL = "https://push.nitrovery.com"
    private static let defaultReminderBaseURL: URL = "https://matrix-bot.nitrovery.com"
    private static let defaultTranscriptionBaseURL: URL = "https://matrix-bot.nitrovery.com"
    
    static var isEnabled: Bool {
        InfoPlistReader.main.isNitroBuild
    }
    
    static var pushGatewayBaseURL: URL {
        resolvedPushGatewayBaseURL(isNitroBuild: isEnabled,
                                   configuredURL: InfoPlistReader.main.nitroPushGatewayBaseURL)
    }
    
    static var reminderBaseURL: URL? {
        resolvedNitroServiceBaseURL(isNitroBuild: isEnabled,
                                    configuredURL: InfoPlistReader.main.nitroReminderBaseURL,
                                    defaultURL: defaultReminderBaseURL)
    }
    
    static var transcriptionBaseURL: URL? {
        resolvedNitroServiceBaseURL(isNitroBuild: isEnabled,
                                    configuredURL: InfoPlistReader.main.nitroTranscriptionBaseURL,
                                    defaultURL: defaultTranscriptionBaseURL)
    }
    
    static func resolvedPushGatewayBaseURL(isNitroBuild: Bool, configuredURL: URL?) -> URL {
        guard isNitroBuild else { return defaultPushGatewayBaseURL }
        return configuredURL ?? defaultNitroPushGatewayBaseURL
    }
    
    static func resolvedNitroServiceBaseURL(isNitroBuild: Bool,
                                            configuredURL: URL?,
                                            defaultURL: URL) -> URL? {
        guard isNitroBuild else { return nil }
        return configuredURL ?? defaultURL
    }
}
