//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import Testing

@MainActor
struct CompletionSuggestionServiceTests {
    @Test
    func userSuggestions() async throws {
        let alice: RoomMemberProxyMock = .mockAlice
        let members: [RoomMemberProxyMock] = [alice, .mockBob, .mockCharlie, .mockMe]
        let roomProxyMock = JoinedRoomProxyMock(.init(id: "roomID", name: "test", members: members))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))
        let service = CompletionSuggestionService(roomProxy: roomProxyMock,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher())
        
        var deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == []
        }
        
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .user(.init(id: alice.userID, displayName: alice.displayName, avatarURL: alice.avatarURL)), range: .init(), rawSuggestionText: "ali")]
        }
        service.setSuggestionTrigger(.init(type: .user, text: "ali", range: .init()))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == []
        }
        service.setSuggestionTrigger(.init(type: .user, text: "me", range: .init()))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == []
        }
        service.setSuggestionTrigger(.init(type: .user, text: "room", range: .init()))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == []
        }
        service.setSuggestionTrigger(.init(type: .user, text: "everyon", range: .init()))
        try await deferred.fulfill()
    }
    
    @Test
    func userSuggestionsIncludingAllUsers() async throws {
        let alice: RoomMemberProxyMock = .mockAlice
        let members: [RoomMemberProxyMock] = [alice, .mockBob, .mockCharlie, .mockMe]
        let roomProxyMock = JoinedRoomProxyMock(.init(id: "roomID",
                                                      name: "test",
                                                      members: members,
                                                      powerLevelsConfiguration: .init(canUserTriggerRoomNotification: true)))
        
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))
        let service = CompletionSuggestionService(roomProxy: roomProxyMock,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher())
        
        var deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == []
        }
        
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .allUsers(.room(id: "roomID", name: "test", avatarURL: nil)), range: .init(), rawSuggestionText: "ro")]
        }
        service.setSuggestionTrigger(.init(type: .user, text: "ro", range: .init()))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .allUsers(.room(id: "roomID", name: "test", avatarURL: nil)), range: .init(), rawSuggestionText: "every")]
        }
        service.setSuggestionTrigger(.init(type: .user, text: "every", range: .init()))
        try await deferred.fulfill()
    }
    
    @Test
    func userSuggestionsWithEmptyText() async throws {
        let alice: RoomMemberProxyMock = .mockAlice
        let bob: RoomMemberProxyMock = .mockBob
        let members: [RoomMemberProxyMock] = [alice, bob, .mockMe]
        let roomProxyMock = JoinedRoomProxyMock(.init(id: "roomID",
                                                      name: "test",
                                                      members: members,
                                                      powerLevelsConfiguration: .init(canUserTriggerRoomNotification: true)))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))
        let service = CompletionSuggestionService(roomProxy: roomProxyMock,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher())
        
        var deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == []
        }
        
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .allUsers(.room(id: "roomID", name: "test", avatarURL: nil)), range: .init(), rawSuggestionText: ""),
                            .init(suggestionType: .user(.init(id: alice.userID, displayName: alice.displayName, avatarURL: alice.avatarURL)), range: .init(), rawSuggestionText: ""),
                            .init(suggestionType: .user(.init(id: bob.userID, displayName: bob.displayName, avatarURL: bob.avatarURL)), range: .init(), rawSuggestionText: "")]
        }
        service.setSuggestionTrigger(.init(type: .user, text: "", range: .init()))
        try await deferred.fulfill()
        
        // Let's test the same with the processTextMessage method
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .allUsers(.room(id: "roomID", name: "test", avatarURL: nil)), range: .init(location: 0, length: 1), rawSuggestionText: ""),
                            .init(suggestionType: .user(.init(id: alice.userID, displayName: alice.displayName, avatarURL: alice.avatarURL)), range: .init(location: 0, length: 1), rawSuggestionText: ""),
                            .init(suggestionType: .user(.init(id: bob.userID, displayName: bob.displayName, avatarURL: bob.avatarURL)), range: .init(location: 0, length: 1), rawSuggestionText: "")]
        }
        service.processTextMessage("@", selectedRange: .init(location: 0, length: 1))
        try await deferred.fulfill()
    }
    
    @Test
    func userSuggestionInDifferentMessagePositions() async throws {
        let alice: RoomMemberProxyMock = .mockAlice
        let members: [RoomMemberProxyMock] = [alice, .mockBob, .mockCharlie, .mockMe]
        let roomProxyMock = JoinedRoomProxyMock(.init(name: "test", members: members))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))
        let service = CompletionSuggestionService(roomProxy: roomProxyMock,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher())
        
        var deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .user(.init(id: alice.userID, displayName: alice.displayName, avatarURL: alice.avatarURL)), range: .init(location: 0, length: 3), rawSuggestionText: "al")]
        }
        service.processTextMessage("@al hello", selectedRange: .init(location: 0, length: 1))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .user(.init(id: alice.userID, displayName: alice.displayName, avatarURL: alice.avatarURL)), range: .init(location: 5, length: 3), rawSuggestionText: "al")]
        }
        service.processTextMessage("test @al", selectedRange: .init(location: 5, length: 1))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .user(.init(id: alice.userID, displayName: alice.displayName, avatarURL: alice.avatarURL)), range: .init(location: 5, length: 3), rawSuggestionText: "al")]
        }
        service.processTextMessage("test @al test", selectedRange: .init(location: 5, length: 1))
        try await deferred.fulfill()
    }
    
    @Test
    func userSuggestionWithMultipleMentionSymbol() async throws {
        let alice: RoomMemberProxyMock = .mockAlice
        let bob: RoomMemberProxyMock = .mockBob
        let members: [RoomMemberProxyMock] = [alice, bob, .mockCharlie, .mockMe]
        let roomProxyMock = JoinedRoomProxyMock(.init(name: "test", members: members))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))
        let service = CompletionSuggestionService(roomProxy: roomProxyMock,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher())
        
        var deffered = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .user(.init(id: alice.userID, displayName: alice.displayName, avatarURL: alice.avatarURL)), range: .init(location: 0, length: 3), rawSuggestionText: "al")]
        }
        service.processTextMessage("@al test @bo", selectedRange: .init(location: 0, length: 1))
        try await deffered.fulfill()
        
        deffered = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .user(.init(id: bob.userID, displayName: bob.displayName, avatarURL: bob.avatarURL)), range: .init(location: 9, length: 3), rawSuggestionText: "bo")]
        }
        service.processTextMessage("@al test @bo", selectedRange: .init(location: 9, length: 1))
        try await deffered.fulfill()
        
        deffered = deferFulfillment(service.suggestionsPublisher) { suggestion in
            suggestion == []
        }
        service.processTextMessage("@al test @bo", selectedRange: .init(location: 4, length: 1))
        try await deffered.fulfill()
    }
    
    @Test
    func roomSuggestions() async throws {
        let alice: RoomMemberProxyMock = .mockAlice
        // We keep the users in the tests since they should not appear in the suggestions when using the room trigger
        let members: [RoomMemberProxyMock] = [alice, .mockBob, .mockCharlie, .mockMe]
        let roomProxyMock = JoinedRoomProxyMock(.init(id: "roomID", name: "test", members: members))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))
        let service = CompletionSuggestionService(roomProxy: roomProxyMock,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher())
        
        var deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == []
        }
        
        try await deferred.fulfill()
        
        // The empty # should trigger suggestions from any room with an alias
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .room(.init(id: "2",
                                                              canonicalAlias: "#foundation-and-empire:matrix.org",
                                                              name: "Foundation and Empire",
                                                              avatar: .room(id: "2",
                                                                            name: "Foundation and Empire",
                                                                            avatarURL: .mockMXCAvatar))),
                                  range: .init(),
                                  rawSuggestionText: ""),
                            .init(suggestionType: .room(.init(id: "6",
                                                              canonicalAlias: "#prelude-foundation:matrix.org",
                                                              name: "Prelude to Foundation",
                                                              avatar: .room(id: "6",
                                                                            name: "Prelude to Foundation",
                                                                            avatarURL: nil))),
                                  range: .init(),
                                  rawSuggestionText: "")]
        }
        service.setSuggestionTrigger(.init(type: .room, text: "", range: .init()))
        try await deferred.fulfill()
        
        // Same but with the processTextMessage method
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .room(.init(id: "2",
                                                              canonicalAlias: "#foundation-and-empire:matrix.org",
                                                              name: "Foundation and Empire",
                                                              avatar: .room(id: "2",
                                                                            name: "Foundation and Empire",
                                                                            avatarURL: .mockMXCAvatar))),
                                  range: .init(location: 0, length: 1),
                                  rawSuggestionText: ""),
                            .init(suggestionType: .room(.init(id: "6",
                                                              canonicalAlias: "#prelude-foundation:matrix.org",
                                                              name: "Prelude to Foundation",
                                                              avatar: .room(id: "6",
                                                                            name: "Prelude to Foundation",
                                                                            avatarURL: nil))),
                                  range: .init(location: 0, length: 1),
                                  rawSuggestionText: "")]
        }
        service.processTextMessage("#", selectedRange: .init(location: 0, length: 1))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .room(.init(id: "6",
                                                              canonicalAlias: "#prelude-foundation:matrix.org",
                                                              name: "Prelude to Foundation",
                                                              avatar: .room(id: "6",
                                                                            name: "Prelude to Foundation",
                                                                            avatarURL: nil))),
                                  range: .init(),
                                  rawSuggestionText: "prelude")]
        }
        service.setSuggestionTrigger(.init(type: .room, text: "prelude", range: .init()))
        try await deferred.fulfill()
    }
    
    @Test
    func roomSuggestionInDifferentMessagePositions() async throws {
        let alice: RoomMemberProxyMock = .mockAlice
        // We keep the users in the tests since they should not appear in the suggestions when using the room trigger
        let members: [RoomMemberProxyMock] = [alice, .mockBob, .mockCharlie, .mockMe]
        let roomProxyMock = JoinedRoomProxyMock(.init(id: "roomID", name: "test", members: members))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))
        let service = CompletionSuggestionService(roomProxy: roomProxyMock,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher())
        
        var deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .room(.init(id: "6",
                                                              canonicalAlias: "#prelude-foundation:matrix.org",
                                                              name: "Prelude to Foundation",
                                                              avatar: .room(id: "6",
                                                                            name: "Prelude to Foundation",
                                                                            avatarURL: nil))),
                                  range: .init(location: 0, length: 3),
                                  rawSuggestionText: "pr")]
        }
        service.processTextMessage("#pr hello", selectedRange: .init(location: 0, length: 1))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .room(.init(id: "6",
                                                              canonicalAlias: "#prelude-foundation:matrix.org",
                                                              name: "Prelude to Foundation",
                                                              avatar: .room(id: "6",
                                                                            name: "Prelude to Foundation",
                                                                            avatarURL: nil))),
                                  range: .init(location: 5, length: 3),
                                  rawSuggestionText: "pr")]
        }
        service.processTextMessage("test #pr", selectedRange: .init(location: 5, length: 1))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .room(.init(id: "6",
                                                              canonicalAlias: "#prelude-foundation:matrix.org",
                                                              name: "Prelude to Foundation",
                                                              avatar: .room(id: "6",
                                                                            name: "Prelude to Foundation",
                                                                            avatarURL: nil))),
                                  range: .init(location: 5, length: 3),
                                  rawSuggestionText: "pr")]
        }
        service.processTextMessage("test #pr test", selectedRange: .init(location: 5, length: 1))
        try await deferred.fulfill()
    }
    
    @Test
    func roomSuggestionWithMultipleMentionSymbol() async throws {
        let alice: RoomMemberProxyMock = .mockAlice
        // We keep the users in the tests since they should not appear in the suggestions when using the room trigger
        let members: [RoomMemberProxyMock] = [alice, .mockBob, .mockCharlie, .mockMe]
        let roomProxyMock = JoinedRoomProxyMock(.init(id: "roomID", name: "test", members: members))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))
        let service = CompletionSuggestionService(roomProxy: roomProxyMock,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher())
        
        var deffered = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .room(.init(id: "6",
                                                              canonicalAlias: "#prelude-foundation:matrix.org",
                                                              name: "Prelude to Foundation",
                                                              avatar: .room(id: "6",
                                                                            name: "Prelude to Foundation",
                                                                            avatarURL: nil))),
                                  range: .init(location: 0, length: 3),
                                  rawSuggestionText: "pr")]
        }
        service.processTextMessage("#pr test #fo", selectedRange: .init(location: 0, length: 1))
        try await deffered.fulfill()
        
        deffered = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .room(.init(id: "2",
                                                              canonicalAlias: "#foundation-and-empire:matrix.org",
                                                              name: "Foundation and Empire",
                                                              avatar: .room(id: "2",
                                                                            name: "Foundation and Empire",
                                                                            avatarURL: .mockMXCAvatar))),
                                  range: .init(location: 9, length: 3),
                                  rawSuggestionText: "fo"),
                            .init(suggestionType: .room(.init(id: "6",
                                                              canonicalAlias: "#prelude-foundation:matrix.org",
                                                              name: "Prelude to Foundation",
                                                              avatar: .room(id: "6",
                                                                            name: "Prelude to Foundation",
                                                                            avatarURL: nil))),
                                  range: .init(location: 9, length: 3),
                                  rawSuggestionText: "fo")]
        }
        service.processTextMessage("#pr test #fo", selectedRange: .init(location: 9, length: 1))
        try await deffered.fulfill()
        
        deffered = deferFulfillment(service.suggestionsPublisher) { suggestion in
            suggestion == []
        }
        service.processTextMessage("#pr test #fo", selectedRange: .init(location: 4, length: 1))
        try await deffered.fulfill()
    }
    
    @Test
    func suggestionsWithMultipleDifferentTriggers() async throws {
        let alice: RoomMemberProxyMock = .mockAlice
        // We keep the users in the tests since they should not appear in the suggestions when using the room trigger
        let members: [RoomMemberProxyMock] = [alice, .mockBob, .mockCharlie, .mockMe]
        let roomProxyMock = JoinedRoomProxyMock(.init(id: "roomID", name: "test", members: members))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))
        let service = CompletionSuggestionService(roomProxy: roomProxyMock,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher())
        
        var deffered = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .room(.init(id: "6",
                                                              canonicalAlias: "#prelude-foundation:matrix.org",
                                                              name: "Prelude to Foundation",
                                                              avatar: .room(id: "6",
                                                                            name: "Prelude to Foundation",
                                                                            avatarURL: nil))),
                                  range: .init(location: 0, length: 3),
                                  rawSuggestionText: "pr")]
        }
        service.processTextMessage("#pr test @al", selectedRange: .init(location: 0, length: 1))
        try await deffered.fulfill()
        
        deffered = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .user(.init(id: alice.userID, displayName: alice.displayName, avatarURL: alice.avatarURL)), range: .init(location: 9, length: 3), rawSuggestionText: "al")]
        }
        service.processTextMessage("#pr test @al", selectedRange: .init(location: 9, length: 1))
        try await deffered.fulfill()
    }
    
    @Test
    func suggestionsContainingNonAlphanumericCharacters() async throws {
        let alice: RoomMemberProxyMock = .mockAlice
        // We keep the users in the tests since they should not appear in the suggestions when using the room trigger
        let members: [RoomMemberProxyMock] = [alice, .mockBob, .mockCharlie, .mockMe]
        let roomProxyMock = JoinedRoomProxyMock(.init(id: "roomID", name: "test", members: members))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded(.mockRooms)))
        let service = CompletionSuggestionService(roomProxy: roomProxyMock,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher())
        
        var deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == []
        }
        
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .room(.init(id: "6",
                                                              canonicalAlias: "#prelude-foundation:matrix.org",
                                                              name: "Prelude to Foundation",
                                                              avatar: .room(id: "6",
                                                                            name: "Prelude to Foundation",
                                                                            avatarURL: nil))),
                                  range: .init(),
                                  rawSuggestionText: "#prelude-")]
        }
        service.setSuggestionTrigger(.init(type: .room, text: "#prelude-", range: .init()))
        try await deferred.fulfill()
    }
    
    @Test
    func emojiSuggestionsIncludeCustomAndSystemEmoji() async throws {
        let customEmoji = try CustomEmoji(shortcode: "meatspin",
                                          body: "Meatspin",
                                          imageURL: #require(URL(string: "mxc://example.org/meatspin")))
        let customItem = EmojiItem(label: "Meatspin",
                                   unicode: ":meatspin:",
                                   keywords: ["spin"],
                                   shortcodes: ["meatspin"],
                                   customEmoji: customEmoji)
        let systemItem = EmojiItem(label: "Grinning face",
                                   unicode: "😀",
                                   keywords: ["smile"],
                                   shortcodes: ["grinning"])
        let emojiProvider = CompletionTestEmojiProvider(categories: [.init(id: "test", emojis: [customItem, systemItem])])
        let roomProxy = JoinedRoomProxyMock(.init(id: "roomID", name: "test"))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded([])))
        let service = CompletionSuggestionService(roomProxy: roomProxy,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher(),
                                                  emojiProvider: emojiProvider)
        
        await Task.yield()
        #expect(emojiProvider.categoryRequests == 0)
        
        var deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .emoji(customItem),
                                  range: .init(location: 6, length: 4),
                                  rawSuggestionText: "mea")]
        }
        service.processTextMessage("Hello :mea", selectedRange: .init(location: 10, length: 0))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .emoji(systemItem),
                                  range: .init(location: 0, length: 4),
                                  rawSuggestionText: "smi")]
        }
        service.processTextMessage(":smi", selectedRange: .init(location: 4, length: 0))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .emoji(customItem),
                                  range: .init(location: 1, length: 4),
                                  rawSuggestionText: "mea")]
        }
        service.processTextMessage("(:mea", selectedRange: .init(location: 5, length: 0))
        try await deferred.fulfill()
        
        deferred = deferFulfillment(service.suggestionsPublisher) { $0.isEmpty }
        service.processTextMessage("https://example.org", selectedRange: .init(location: 6, length: 0))
        try await deferred.fulfill()
        #expect(emojiProvider.categoryRequests == 1)
    }
    
    @Test
    func duplicateCustomEmojiSuggestionsUseFirstCategory() async throws {
        let currentEmoji = try CustomEmoji(shortcode: "shared",
                                           body: "Current",
                                           imageURL: #require(URL(string: "mxc://example.org/current")))
        let globalEmoji = try CustomEmoji(shortcode: "shared",
                                          body: "Global",
                                          imageURL: #require(URL(string: "mxc://example.org/global")))
        let currentItem = EmojiItem(label: "Current",
                                    unicode: ":shared:",
                                    keywords: [],
                                    shortcodes: ["shared"],
                                    customEmoji: currentEmoji)
        let globalItem = EmojiItem(label: "Global",
                                   unicode: ":shared:",
                                   keywords: [],
                                   shortcodes: ["shared"],
                                   customEmoji: globalEmoji)
        let emojiProvider = CompletionTestEmojiProvider(categories: [
            .init(id: "current", emojis: [currentItem]),
            .init(id: "global", emojis: [globalItem])
        ])
        let roomProxy = JoinedRoomProxyMock(.init(id: "roomID", name: "test"))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded([])))
        let service = CompletionSuggestionService(roomProxy: roomProxy,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher(),
                                                  emojiProvider: emojiProvider)
        let deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .emoji(currentItem),
                                  range: .init(location: 0, length: 4),
                                  rawSuggestionText: "sha")]
        }
        
        service.processTextMessage(":sha", selectedRange: .init(location: 4, length: 0))
        
        try await deferred.fulfill()
    }
    
    @Test
    func emojiSuggestionsUseFrequencyButKeepExactMatchFirst() async throws {
        let exactItem = EmojiItem(label: "Heart",
                                  unicode: "❤️",
                                  keywords: [],
                                  shortcodes: ["heart"])
        let frequentItem = EmojiItem(label: "Hearts",
                                     unicode: "💕",
                                     keywords: [],
                                     shortcodes: ["hearts"])
        let emojiProvider = CompletionTestEmojiProvider(categories: [.init(id: "symbols", emojis: [exactItem, frequentItem])],
                                                        usageRanks: [frequentItem.reactionKey: 0])
        let roomProxy = JoinedRoomProxyMock(.init(id: "roomID", name: "test"))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded([])))
        let service = CompletionSuggestionService(roomProxy: roomProxy,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher(),
                                                  emojiProvider: emojiProvider)
        
        var deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions.map(\.suggestionType) == [.emoji(frequentItem), .emoji(exactItem)]
        }
        service.processTextMessage(":hea", selectedRange: .init(location: 4, length: 0))
        try await deferred.fulfill()
        
        emojiProvider.recentEmojiUsageRanks = [exactItem.reactionKey: 0]
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions.map(\.suggestionType) == [.emoji(exactItem), .emoji(frequentItem)]
        }
        service.processTextMessage(":hea", selectedRange: .init(location: 4, length: 0))
        try await deferred.fulfill()
        #expect(emojiProvider.categoryRequests == 1)
        
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions.map(\.suggestionType) == [.emoji(exactItem), .emoji(frequentItem)]
        }
        service.processTextMessage(":heart", selectedRange: .init(location: 6, length: 0))
        try await deferred.fulfill()
    }
    
    @Test
    func emojiSuggestionsRefreshAfterCacheLifetime() async throws {
        let firstItem = EmojiItem(label: "First",
                                  unicode: "1️⃣",
                                  keywords: [],
                                  shortcodes: ["first"])
        let secondItem = EmojiItem(label: "Second",
                                   unicode: "2️⃣",
                                   keywords: [],
                                   shortcodes: ["second"])
        let emojiProvider = CompletionTestEmojiProvider(categoryResponses: [
            [.init(id: "first", emojis: [firstItem])],
            [.init(id: "second", emojis: [secondItem])]
        ])
        let roomProxy = JoinedRoomProxyMock(.init(id: "roomID", name: "test"))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded([])))
        var currentDate = Date()
        let service = CompletionSuggestionService(roomProxy: roomProxy,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher(),
                                                  emojiProvider: emojiProvider) { currentDate }
        var deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .emoji(firstItem),
                                  range: .init(location: 0, length: 4),
                                  rawSuggestionText: "fir")]
        }
        service.processTextMessage(":fir", selectedRange: .init(location: 4, length: 0))
        try await deferred.fulfill()
        #expect(emojiProvider.categoryRequests == 1)
        
        service.setSuggestionTrigger(nil)
        currentDate.addTimeInterval(5 * 60 + 1)
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .emoji(secondItem),
                                  range: .init(location: 0, length: 4),
                                  rawSuggestionText: "sec")]
        }
        service.processTextMessage(":sec", selectedRange: .init(location: 4, length: 0))
        try await deferred.fulfill()
        #expect(emojiProvider.categoryRequests == 2)
    }
    
    @Test
    func emojiSuggestionsRetrySoonAfterFailedLoad() async throws {
        let fallbackItem = EmojiItem(label: "Fallback",
                                     unicode: "🔁",
                                     keywords: [],
                                     shortcodes: ["fallback"])
        let recoveredItem = EmojiItem(label: "Recovered",
                                      unicode: "✅",
                                      keywords: [],
                                      shortcodes: ["recovered"])
        let emojiProvider = CompletionTestEmojiProvider(categoryResponses: [
            [.init(id: "fallback", emojis: [fallbackItem])],
            [.init(id: "recovered", emojis: [recoveredItem])]
        ], loadFailures: [true, false])
        let roomProxy = JoinedRoomProxyMock(.init(id: "roomID", name: "test"))
        let roomSummaryProvider = RoomSummaryProviderMock(.init(state: .loaded([])))
        var currentDate = Date()
        let service = CompletionSuggestionService(roomProxy: roomProxy,
                                                  roomListPublisher: roomSummaryProvider.roomListPublisher.eraseToAnyPublisher(),
                                                  emojiProvider: emojiProvider) { currentDate }
        var deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .emoji(fallbackItem),
                                  range: .init(location: 0, length: 4),
                                  rawSuggestionText: "fal")]
        }
        service.processTextMessage(":fal", selectedRange: .init(location: 4, length: 0))
        try await deferred.fulfill()
        #expect(emojiProvider.categoryRequests == 1)
        
        service.setSuggestionTrigger(nil)
        currentDate.addTimeInterval(31)
        deferred = deferFulfillment(service.suggestionsPublisher) { suggestions in
            suggestions == [.init(suggestionType: .emoji(recoveredItem),
                                  range: .init(location: 0, length: 4),
                                  rawSuggestionText: "rec")]
        }
        service.processTextMessage(":rec", selectedRange: .init(location: 4, length: 0))
        try await deferred.fulfill()
        #expect(emojiProvider.categoryRequests == 2)
    }
}

private final class CompletionTestEmojiProvider: EmojiProviderProtocol, NitroEmojiUsageRankingProvider {
    private let categoryResponses: [[EmojiCategory]]
    private let loadFailures: [Bool]
    var recentEmojiUsageRanks: [String: Int]
    private(set) var categoryRequests = 0
    private var lastLoadFailed = false
    
    init(categories: [EmojiCategory], usageRanks: [String: Int] = [:]) {
        categoryResponses = [categories]
        loadFailures = [false]
        recentEmojiUsageRanks = usageRanks
    }
    
    init(categoryResponses: [[EmojiCategory]], loadFailures: [Bool] = []) {
        self.categoryResponses = categoryResponses
        self.loadFailures = loadFailures
        recentEmojiUsageRanks = [:]
    }
    
    func categories(searchString: String?) async -> [EmojiCategory] {
        let responseIndex = min(categoryRequests, categoryResponses.count - 1)
        lastLoadFailed = loadFailures.indices.contains(responseIndex) ? loadFailures[responseIndex] : false
        categoryRequests += 1
        return categoryResponses[responseIndex]
    }
    
    func shouldRetryLoadingCategories() -> Bool {
        lastLoadFailed
    }
    
    func frequentlyUsedSystemEmojis() -> [String] {
        []
    }
    
    func markEmojiAsFrequentlyUsed(_ emoji: String) { }
}
