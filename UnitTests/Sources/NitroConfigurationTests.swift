//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Testing

struct NitroConfigurationTests {
    @Test
    func loadsNitroVariantValues() {
        #expect(NitroConfiguration.isEnabled)
        #expect(NitroConfiguration.pushGatewayBaseURL == "https://push.nitrovery.com")
        #expect(NitroConfiguration.reminderBaseURL == "https://matrix-bot.nitrovery.com")
        #expect(NitroConfiguration.transcriptionBaseURL == "https://matrix-bot.nitrovery.com")
        #expect(NitroConfiguration.sentryURL == "https://d875c82c8d742fe7292ad47e7d6b9a4d@o4511974887784448.ingest.de.sentry.io/4511975003848784")
        #expect(InfoPlistReader.main.classicAppGroupIdentifier == nil)
        #expect(InfoPlistReader.main.classicAppKeychainServiceIdentifier == nil)
        #expect(InfoPlistReader.main.classicAppKeychainAccessGroupIdentifier == nil)
        #expect(InfoPlistReader.main.classicAppDeepLinkURL == nil)
    }

    @Test
    func enablesClientPausingAndResuming() {
        #expect(AppSettings.volatile().clientPausingAndResumingEnabled)
    }
    
    @Test
    func nonNitroBuildUsesUpstreamServices() {
        #expect(NitroConfiguration.resolvedPushGatewayBaseURL(isNitroBuild: false,
                                                              configuredURL: "https://push.nitrovery.com") == "https://matrix.org")
        #expect(NitroConfiguration.resolvedNitroServiceBaseURL(isNitroBuild: false,
                                                               configuredURL: "https://matrix-bot.nitrovery.com",
                                                               defaultURL: "https://matrix-bot.nitrovery.com") == nil)
    }
}
