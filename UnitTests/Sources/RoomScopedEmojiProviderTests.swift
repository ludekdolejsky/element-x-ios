//
// Copyright 2026 Element Creations Ltd.
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
struct RoomScopedEmojiProviderTests {
    private let currentRoomID = "!current:example.org"
    private let globalRoomID = "!global:example.org"
    private let spaceRoomID = "!space:example.org"
    private let userID = "@alice:example.org"
    
    @Test
    func loadsStablePacksInSpecifiedPriorityOrder() async {
        let baseEmoji = EmojiItem(label: "Wave", unicode: "👋", keywords: [], shortcodes: ["wave"])
        let provider = makeProvider(baseCategories: [.init(id: "people", emojis: [baseEmoji])],
                                    accountData: [
                                        "m.image_pack.rooms": #"{"rooms":{"!global:example.org":{"global-pack":{}}}}"#
                                    ],
                                    roomStates: [
                                        currentRoomID: [
                                            roomNameEvent(roomID: currentRoomID, name: "Current room"),
                                            imagePackEvent(roomID: currentRoomID, stateKey: "current-pack", name: "Current pack", shortcode: "current"),
                                            .init(roomID: currentRoomID,
                                                  type: "m.space.parent",
                                                  stateKey: spaceRoomID,
                                                  content: #"{"canonical":true}"#)
                                        ],
                                        globalRoomID: [
                                            roomNameEvent(roomID: globalRoomID, name: "Global room"),
                                            imagePackEvent(roomID: globalRoomID, stateKey: "global-pack", name: "Global pack", shortcode: "global")
                                        ],
                                        spaceRoomID: [
                                            roomNameEvent(roomID: spaceRoomID, name: "Space"),
                                            membershipEvent(roomID: spaceRoomID, userID: userID),
                                            imagePackEvent(roomID: spaceRoomID, stateKey: "space-pack", name: "Space pack", shortcode: "space")
                                        ]
                                    ])
        
        let categories = await provider.categories(searchString: nil)
        
        #expect(categories.map(\.name) == ["Current pack", "Space pack", nil, "Global pack"])
        #expect(categories.compactMap { $0.emojis.first?.reactionKey } == [
            "mxc://example.org/current",
            "mxc://example.org/space",
            "👋",
            "mxc://example.org/global"
        ])
    }
    
    @Test
    func buildsUnifiedRecentCategoryFromStableLegacyAndLocalData() async {
        let wave = EmojiItem(label: "Wave", unicode: "👋", keywords: [], shortcodes: ["wave"])
        let thumbsUp = EmojiItem(label: "Thumbs up", unicode: "👍", keywords: [], shortcodes: ["thumbsup"])
        let provider = makeProvider(baseCategories: [.init(id: "people", emojis: [wave, thumbsUp])],
                                    accountData: [
                                        "m.recent_emoji": """
                                        {"recent_emoji":[
                                          {"emoji":"mxc://example.org/current","total":3,"shortcode":"current"},
                                          {"emoji":"👋","total":1},
                                          {"emoji":"mxc://example.org/missing","total":99,"shortcode":"missing"}
                                        ]}
                                        """,
                                        "io.element.recent_emoji": """
                                        {"recent_emoji":[["👍",4],["mxc://example.org/global",2]]}
                                        """,
                                        "m.image_pack.rooms": #"{"rooms":{"!global:example.org":{"global-pack":{}}}}"#
                                    ],
                                    roomStates: [
                                        currentRoomID: [
                                            imagePackEvent(roomID: currentRoomID,
                                                           stateKey: "current-pack",
                                                           name: "Current pack",
                                                           shortcode: "current")
                                        ],
                                        globalRoomID: [
                                            imagePackEvent(roomID: globalRoomID,
                                                           stateKey: "global-pack",
                                                           name: "Global pack",
                                                           shortcode: "global")
                                        ]
                                    ])
        
        let categories = await provider.categories(searchString: nil)
        
        #expect(categories.map(\.id) == [
            EmojiCategory.frequentlyUsedCategoryIdentifier,
            "io.element.elementx.custom.!current:example.org|current-pack",
            "people",
            "io.element.elementx.custom.!global:example.org|global-pack"
        ])
        #expect(categories.first?.emojis.map(\.reactionKey) == [
            "👍",
            "mxc://example.org/current",
            "mxc://example.org/global",
            "👋"
        ])
    }
    
    @Test
    func recordsCustomEmojiInStableAccountData() async throws {
        var writtenEventType: String?
        var writtenContent: String?
        let provider = RoomScopedEmojiProvider(roomID: currentRoomID,
                                               userID: userID,
                                               baseProvider: TestRoomEmojiProvider(categories: []),
                                               accountDataProvider: { eventType in
                                                   let content = eventType == "m.recent_emoji"
                                                       ? #"{"recent_emoji":[{"emoji":"👋","total":2}]}"#
                                                       : nil
                                                   return .success(content)
                                               },
                                               accountDataWriter: { eventType, content in
                                                   writtenEventType = eventType
                                                   writtenContent = content
                                                   return .success(())
                                               },
                                               roomStateProvider: { _ in .success([]) })
        
        await provider.markEmojiAsRecentlyUsed("mxc://example.org/party", shortcode: "party")
        
        let content = try #require(writtenContent?.data(using: .utf8))
        let accountData = try JSONDecoder().decode(RecentEmojiAccountData.self, from: content)
        #expect(writtenEventType == "m.recent_emoji")
        #expect(accountData.recentEmoji == [
            .init(emoji: "mxc://example.org/party", total: 1, shortcode: "party"),
            .init(emoji: "👋", total: 2, shortcode: nil)
        ])
    }
    
    @Test
    func loadsCustomEmojisFromColdCacheWithoutLoadingBaseCategories() async {
        let baseEmoji = EmojiItem(label: "Wave", unicode: "👋", keywords: [], shortcodes: ["wave"])
        let baseProvider = TestRoomEmojiProvider(categories: [.init(id: "people", emojis: [baseEmoji])])
        let provider = RoomScopedEmojiProvider(roomID: currentRoomID,
                                               userID: userID,
                                               baseProvider: baseProvider,
                                               accountDataProvider: { _ in .success(nil) },
                                               roomStateProvider: { roomID in
                                                   .success([
                                                       imagePackEvent(roomID: roomID,
                                                                      stateKey: "party-pack",
                                                                      name: "Party pack",
                                                                      shortcode: "party")
                                                   ])
                                               })
        
        #expect(provider.cachedCustomEmojis().isEmpty)
        
        let customEmojis = await provider.customEmojis()
        
        #expect(customEmojis.map(\.shortcode) == ["party"])
        #expect(provider.cachedCustomEmojis().map(\.shortcode) == ["party"])
        #expect(baseProvider.categoriesCallCount == 0)
    }
    
    @Test
    func duplicateShortcodesKeepHighestPriorityPackOnly() async {
        let provider = makeProvider(accountData: [
            "m.image_pack.rooms": #"{"rooms":{"!global:example.org":{"global-pack":{}}}}"#
        ], roomStates: [
            currentRoomID: [
                imagePackEvent(roomID: currentRoomID,
                               stateKey: "current-pack",
                               name: "Zulu current",
                               shortcode: "shared",
                               mxcPath: "current"),
                .init(roomID: currentRoomID,
                      type: "m.space.parent",
                      stateKey: spaceRoomID,
                      content: #"{"canonical":true}"#)
            ],
            spaceRoomID: [
                membershipEvent(roomID: spaceRoomID, userID: userID),
                imagePackEvent(roomID: spaceRoomID,
                               stateKey: "space-pack",
                               name: "Aardvark space",
                               shortcode: "shared",
                               mxcPath: "space")
            ],
            globalRoomID: [
                imagePackEvent(roomID: globalRoomID,
                               stateKey: "global-pack",
                               name: "Alpha global",
                               shortcode: "shared",
                               mxcPath: "global")
            ]
        ])
        
        _ = await provider.categories(searchString: nil)
        let matchingEmojis = provider.cachedCustomEmojis().filter { $0.shortcode == "shared" }
        
        #expect(matchingEmojis.map(\.imageURL.absoluteString) == ["mxc://example.org/global"])
    }
    
    @Test
    func supportsLegacyGlobalReferencesAndPrefersStablePackEvents() async {
        let legacyRoomID = "!legacy:example.org"
        let provider = makeProvider(accountData: [
            "im.ponies.emote_rooms": #"{"rooms":{"!legacy:example.org":{}}}"#
        ], roomStates: [
            currentRoomID: [],
            legacyRoomID: [
                imagePackEvent(roomID: legacyRoomID,
                               type: "im.ponies.room_emotes",
                               stateKey: "pack",
                               name: "Legacy duplicate",
                               shortcode: "legacy"),
                imagePackEvent(roomID: legacyRoomID,
                               stateKey: "pack",
                               name: "Stable winner",
                               shortcode: "stable")
            ]
        ])
        
        let categories = await provider.categories(searchString: nil)
        
        #expect(categories.map(\.name) == ["Stable winner"])
        #expect(categories.first?.emojis.first?.reactionKey == "mxc://example.org/stable")
    }
    
    @Test
    func emptyStableGlobalReferenceLoadsAllPacks() async {
        let provider = makeProvider(accountData: [
            "m.image_pack.rooms": #"{"rooms":{"!global:example.org":{}}}"#
        ], roomStates: [
            currentRoomID: [],
            globalRoomID: [
                imagePackEvent(roomID: globalRoomID, stateKey: "first", name: "First", shortcode: "first"),
                imagePackEvent(roomID: globalRoomID, stateKey: "second", name: "Second", shortcode: "second")
            ]
        ])
        
        let categories = await provider.categories(searchString: nil)
        
        #expect(categories.map(\.name) == ["First", "Second"])
        #expect(categories.compactMap { $0.emojis.first?.reactionKey } == [
            "mxc://example.org/first",
            "mxc://example.org/second"
        ])
    }
    
    @Test
    func limitsConcurrentGlobalRoomStateLoads() async throws {
        let globalRoomIDs = (0..<6).map { "!global-\($0):example.org" }
        let roomReferences = globalRoomIDs.map { "\"\($0)\":{}" }.joined(separator: ",")
        let (startedRoomIDs, startedRoomIDsContinuation) = AsyncStream<String>.makeStream()
        var startedRoomIDsIterator = startedRoomIDs.makeAsyncIterator()
        var waiters = [String: CheckedContinuation<Void, Never>]()
        var activeRoomStateLoads = 0
        var maximumActiveRoomStateLoads = 0
        let provider = RoomScopedEmojiProvider(roomID: currentRoomID,
                                               userID: userID,
                                               baseProvider: TestRoomEmojiProvider(categories: []),
                                               accountDataProvider: { eventType in
                                                   guard eventType == "m.image_pack.rooms" else { return .success(nil) }
                                                   return .success(#"{"rooms":{\#(roomReferences)}}"#)
                                               },
                                               roomStateProvider: { roomID in
                                                   guard roomID != currentRoomID else { return .success([]) }
                                                   activeRoomStateLoads += 1
                                                   maximumActiveRoomStateLoads = max(maximumActiveRoomStateLoads, activeRoomStateLoads)
                                                   startedRoomIDsContinuation.yield(roomID)
                                                   await withCheckedContinuation { waiters[roomID] = $0 }
                                                   activeRoomStateLoads -= 1
                                                   return .success([])
                                               })
        let loadTask = Task { await provider.customEmojis() }
        
        var firstBatch = [String]()
        for _ in 0..<4 {
            try firstBatch.append(#require(await startedRoomIDsIterator.next()))
        }
        #expect(activeRoomStateLoads == 4)
        #expect(maximumActiveRoomStateLoads == 4)
        
        waiters.removeValue(forKey: firstBatch[0])?.resume()
        _ = try #require(await startedRoomIDsIterator.next())
        #expect(maximumActiveRoomStateLoads == 4)
        
        for roomID in Array(waiters.keys) {
            waiters.removeValue(forKey: roomID)?.resume()
        }
        let finalRoomID = try #require(await startedRoomIDsIterator.next())
        waiters.removeValue(forKey: finalRoomID)?.resume()
        _ = await loadTask.value
        startedRoomIDsContinuation.finish()
        
        #expect(maximumActiveRoomStateLoads == 4)
    }
    
    @Test
    func ignoresUnjoinedSpaceAndInvalidOrStickerOnlyImages() async {
        let provider = makeProvider(roomStates: [
            currentRoomID: [
                .init(roomID: currentRoomID,
                      type: "m.space.parent",
                      stateKey: spaceRoomID,
                      content: #"{"canonical":true}"#),
                .init(roomID: currentRoomID,
                      type: "m.room.image_pack",
                      stateKey: "filtered-pack",
                      content: """
                      {"images":{
                        "valid":{"url":"mxc://example.org/valid","body":"Valid","usage":["emoticon"]},
                        "web":{"url":"https://example.org/web.png","body":"Web"},
                        "sticker":{"url":"mxc://example.org/sticker","body":"Sticker","usage":["sticker"]}
                      },"pack":{"display_name":"Filtered pack"}}
                      """)
            ],
            spaceRoomID: [
                membershipEvent(roomID: spaceRoomID, userID: userID, membership: "invite"),
                imagePackEvent(roomID: spaceRoomID, stateKey: "space-pack", name: "Hidden space", shortcode: "hidden")
            ]
        ])
        
        let categories = await provider.categories(searchString: nil)
        
        #expect(categories.map(\.name) == ["Filtered pack"])
        #expect(categories.first?.emojis.map(\.label) == ["Valid"])
    }
    
    @Test
    func searchesCachedCustomPacksWithoutReloadingRoomState() async {
        var imagePackAccountDataCalls = 0
        var roomStateCalls = 0
        let baseProvider = TestRoomEmojiProvider(categories: [])
        let provider = RoomScopedEmojiProvider(roomID: currentRoomID,
                                               userID: userID,
                                               baseProvider: baseProvider,
                                               accountDataProvider: { eventType in
                                                   if eventType == "m.image_pack.rooms" || eventType == "im.ponies.emote_rooms" {
                                                       imagePackAccountDataCalls += 1
                                                   }
                                                   return .success(nil)
                                               },
                                               roomStateProvider: { roomID in
                                                   roomStateCalls += 1
                                                   return .success([
                                                       imagePackEvent(roomID: roomID,
                                                                      stateKey: "pack",
                                                                      name: "Party pack",
                                                                      shortcode: "banana-dance",
                                                                      body: "Banana Dance")
                                                   ])
                                               })
        
        _ = await provider.categories(searchString: nil)
        let searchResults = await provider.categories(searchString: "banana")
        
        #expect(searchResults.map(\.name) == ["Party pack"])
        #expect(searchResults.first?.emojis.first?.customEmoji?.shortcode == "banana-dance")
        #expect(imagePackAccountDataCalls == 2)
        #expect(roomStateCalls == 1)
    }
    
    @Test
    func failedCustomPackLoadsBackOffBeforeRetrying() async {
        var imagePackAccountDataCalls = 0
        var now = Date(timeIntervalSince1970: 0)
        let provider = RoomScopedEmojiProvider(roomID: currentRoomID,
                                               userID: userID,
                                               baseProvider: TestRoomEmojiProvider(categories: []),
                                               accountDataProvider: { eventType in
                                                   if eventType == "m.image_pack.rooms" || eventType == "im.ponies.emote_rooms" {
                                                       imagePackAccountDataCalls += 1
                                                       return .failure(.invalidResponse)
                                                   }
                                                   return .success(nil)
                                               },
                                               roomStateProvider: { _ in .success([]) },
                                               now: { now })
        
        _ = await provider.categories(searchString: nil)
        #expect(provider.shouldRetryLoadingCategories())
        _ = await provider.categories(searchString: nil)
        #expect(imagePackAccountDataCalls == 2)
        
        now.addTimeInterval(31)
        _ = await provider.categories(searchString: nil)
        #expect(imagePackAccountDataCalls == 4)
    }
    
    @Test
    func inaccessibleOptionalPackRoomDoesNotTriggerRetries() async {
        var imagePackAccountDataCalls = 0
        var roomStateCalls = [String: Int]()
        let provider = RoomScopedEmojiProvider(roomID: currentRoomID,
                                               userID: userID,
                                               baseProvider: TestRoomEmojiProvider(categories: []),
                                               accountDataProvider: { eventType in
                                                   if eventType == "m.image_pack.rooms" || eventType == "im.ponies.emote_rooms" {
                                                       imagePackAccountDataCalls += 1
                                                   }
                                                   let content = eventType == "m.image_pack.rooms"
                                                       ? #"{"rooms":{"!global:example.org":{"pack":{}}}}"#
                                                       : nil
                                                   return .success(content)
                                               },
                                               roomStateProvider: { roomID in
                                                   roomStateCalls[roomID, default: 0] += 1
                                                   return roomID == globalRoomID ? .failure(.forbiddenAccess) : .success([])
                                               })
        
        _ = await provider.categories(searchString: nil)
        _ = await provider.categories(searchString: nil)
        
        #expect(!provider.shouldRetryLoadingCategories())
        #expect(imagePackAccountDataCalls == 2)
        #expect(roomStateCalls[currentRoomID] == 1)
        #expect(roomStateCalls[globalRoomID] == 1)
    }
    
    @Test
    func transientFailureKeepsStaleCustomEmojiCache() async {
        var now = Date(timeIntervalSince1970: 0)
        var roomStateCalls = 0
        let provider = RoomScopedEmojiProvider(roomID: currentRoomID,
                                               userID: userID,
                                               baseProvider: TestRoomEmojiProvider(categories: []),
                                               accountDataProvider: { _ in .success(nil) },
                                               roomStateProvider: { roomID in
                                                   roomStateCalls += 1
                                                   if roomStateCalls == 1 {
                                                       return .success([
                                                           imagePackEvent(roomID: roomID,
                                                                          stateKey: "pack",
                                                                          name: "Party pack",
                                                                          shortcode: "party")
                                                       ])
                                                   }
                                                   return .failure(.invalidResponse)
                                               },
                                               now: { now })
        
        let initialCategories = await provider.categories(searchString: nil)
        now.addTimeInterval(301)
        let staleCategories = await provider.categories(searchString: nil)
        _ = await provider.categories(searchString: nil)
        
        #expect(initialCategories.first?.emojis.first?.customEmoji?.shortcode == "party")
        #expect(staleCategories.first?.emojis.first?.customEmoji?.shortcode == "party")
        #expect(provider.cachedCustomEmojis().first?.shortcode == "party")
        #expect(provider.shouldRetryLoadingCategories())
        #expect(roomStateCalls == 2)
    }
    
    @Test
    func keepsAliasesForTheSameImageDistinct() async {
        let provider = makeProvider(roomStates: [
            currentRoomID: [
                .init(roomID: currentRoomID,
                      type: "m.room.image_pack",
                      stateKey: "aliases",
                      content: """
                      {"images":{
                        "first":{"url":"mxc://example.org/shared","body":"First"},
                        "second":{"url":"mxc://example.org/shared","body":"Second"}
                      },"pack":{"display_name":"Aliases"}}
                      """)
            ]
        ])
        
        let emojis = await provider.categories(searchString: nil).first?.emojis ?? []
        
        #expect(emojis.count == 2)
        #expect(Set(emojis.map(\.id)).count == 2)
        #expect(Set(emojis.map(\.reactionKey)) == ["mxc://example.org/shared"])
    }
    
    private func makeProvider(baseCategories: [EmojiCategory] = [],
                              accountData: [String: String] = [:],
                              roomStates: [String: [RoomStateEventProxy]]) -> RoomScopedEmojiProvider {
        RoomScopedEmojiProvider(roomID: currentRoomID,
                                userID: userID,
                                baseProvider: TestRoomEmojiProvider(categories: baseCategories),
                                accountDataProvider: { .success(accountData[$0]) },
                                roomStateProvider: { .success(roomStates[$0] ?? []) })
    }
    
    private func imagePackEvent(roomID: String,
                                type: String = "m.room.image_pack",
                                stateKey: String,
                                name: String,
                                shortcode: String,
                                body: String? = nil,
                                mxcPath: String? = nil) -> RoomStateEventProxy {
        .init(roomID: roomID,
              type: type,
              stateKey: stateKey,
              content: """
              {"images":{"\(shortcode)":{"url":"mxc://example.org/\(mxcPath ?? shortcode)","body":"\(body ?? shortcode)","usage":["emoticon"]}},"pack":{"display_name":"\(name)"}}
              """)
    }
    
    private func roomNameEvent(roomID: String, name: String) -> RoomStateEventProxy {
        .init(roomID: roomID, type: "m.room.name", stateKey: "", content: #"{"name":"\#(name)"}"#)
    }
    
    private func membershipEvent(roomID: String, userID: String, membership: String = "join") -> RoomStateEventProxy {
        .init(roomID: roomID, type: "m.room.member", stateKey: userID, content: #"{"membership":"\#(membership)"}"#)
    }
}

private struct RecentEmojiAccountData: Decodable {
    struct Entry: Decodable, Equatable {
        let emoji: String
        let total: UInt64
        let shortcode: String?
    }
    
    let recentEmoji: [Entry]
    
    enum CodingKeys: String, CodingKey {
        case recentEmoji = "recent_emoji"
    }
}

@MainActor
private final class TestRoomEmojiProvider: EmojiProviderProtocol {
    private let loadedCategories: [EmojiCategory]
    private(set) var categoriesCallCount = 0
    
    init(categories: [EmojiCategory]) {
        loadedCategories = categories
    }
    
    func categories(searchString: String?) async -> [EmojiCategory] {
        categoriesCallCount += 1
        return loadedCategories
    }
    
    func frequentlyUsedSystemEmojis() -> [String] {
        []
    }
    
    func markEmojiAsFrequentlyUsed(_ emoji: String) { }
}
