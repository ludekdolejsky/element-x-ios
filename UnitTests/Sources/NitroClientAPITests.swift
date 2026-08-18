//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroClientAPITests {
    @Test
    func roomStateDecodeKeepsOnlyEmojiMetadataAndOwnMembership() async throws {
        let data = Data("""
        [
          {"type":"m.room.image_pack","state_key":"pack","content":{"images":{}}},
          {"type":"im.ponies.room_emotes","state_key":"legacy","content":{"images":{}}},
          {"type":"m.room.name","state_key":"","content":{"name":"Room"}},
          {"type":"m.space.parent","state_key":"!space:example.org","content":{"canonical":true}},
          {"type":"m.room.member","state_key":"@alice:example.org","content":{"membership":"join"}},
          {"type":"m.room.member","state_key":"@bob:example.org","content":{"membership":"join"}},
          {"type":"m.room.topic","state_key":"","content":{"topic":"Not needed"}}
        ]
        """.utf8)
        
        let events = try await NitroClientAPI.decodeEmojiRoomStateEvents(data,
                                                                         roomID: "!room:example.org",
                                                                         ownUserID: "@alice:example.org")
        
        #expect(events.map(\.type) == [
            "m.room.image_pack",
            "im.ponies.room_emotes",
            "m.room.name",
            "m.space.parent",
            "m.room.member"
        ])
        #expect(events.last?.stateKey == "@alice:example.org")
    }
}
