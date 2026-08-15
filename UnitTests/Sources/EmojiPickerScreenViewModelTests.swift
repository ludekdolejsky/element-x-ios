//
// Copyright 2025 Element Creations Ltd.
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
struct EmojiPickerScreenViewModelTests {
    var emojiPickerStream: AsyncStream<EmojiPickerEmojiViewData>!
    
    var viewModel: EmojiPickerScreenViewModel!
    var context: EmojiPickerScreenViewModel.Context {
        viewModel.context
    }
    
    @Test
    mutating func selectEmoji() async throws {
        // Given a freshly presented emoji picker.
        setupViewModel()
        let reaction = "👋"
        
        // When the user taps an emoji.
        let deferred = deferFulfillment(viewModel.actions) { $0 == .dismiss }
        let emoji = EmojiPickerEmojiViewData(id: "wave",
                                             value: reaction,
                                             label: "Wave",
                                             customEmoji: nil)
        context.send(viewAction: .emojiTapped(emoji: emoji))
        
        // Then the screen should dismiss and yield the emoji before finishing the stream.
        try await deferred.fulfill()
        var iterator = emojiPickerStream.makeAsyncIterator()
        #expect(await iterator.next() == emoji)
        #expect(await iterator.next() == nil)
    }
    
    @Test
    mutating func selectCustomEmojiUpdatesRecentEmojis() async throws {
        let customEmoji = try CustomEmoji(shortcode: "party",
                                          body: "Party",
                                          imageURL: #require(URL(string: "mxc://example.org/party")))
        let emoji = EmojiPickerEmojiViewData(id: "party",
                                             value: ":party:",
                                             label: "Party",
                                             customEmoji: customEmoji)
        let emojiProvider = TestEmojiProvider()
        setupViewModel(emojiProvider: emojiProvider)
        var recentEmojiIterator = emojiProvider.recentEmojiStream.makeAsyncIterator()
        
        let deferred = deferFulfillment(viewModel.actions) { $0 == .dismiss }
        context.send(viewAction: .emojiTapped(emoji: emoji))
        
        try await deferred.fulfill()
        var iterator = emojiPickerStream.makeAsyncIterator()
        #expect(await iterator.next() == emoji)
        #expect(emojiProvider.markedEmojis.isEmpty)
        #expect(await recentEmojiIterator.next() == .init(emoji: "mxc://example.org/party", shortcode: "party"))
    }
    
    @Test
    mutating func stopFinishesTheStream() async {
        // Given a freshly presented emoji picker.
        setupViewModel()
        
        // When it is stopped without a selection (e.g. the picker is dismissed).
        viewModel.stop()
        
        // Then the stream should finish without yielding an emoji.
        var iterator = emojiPickerStream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
    
    // MARK: - Helpers
    
    private mutating func setupViewModel(selectedEmojis: Set<String> = [],
                                         emojiProvider: EmojiProviderProtocol = EmojiProvider(appSettings: .volatile())) {
        let (stream, continuation) = AsyncStream<EmojiPickerEmojiViewData>.makeStream()
        emojiPickerStream = stream
        
        viewModel = EmojiPickerScreenViewModel(selectedEmojis: selectedEmojis,
                                               emojiProvider: emojiProvider,
                                               continuation: continuation)
    }
}

@MainActor
private final class TestEmojiProvider: EmojiProviderProtocol {
    struct RecentEmoji: Equatable {
        let emoji: String
        let shortcode: String?
    }
    
    var markedEmojis = [String]()
    let recentEmojiStream: AsyncStream<RecentEmoji>
    private let recentEmojiContinuation: AsyncStream<RecentEmoji>.Continuation
    
    init() {
        let streamAndContinuation = AsyncStream<RecentEmoji>.makeStream()
        recentEmojiStream = streamAndContinuation.stream
        recentEmojiContinuation = streamAndContinuation.continuation
    }
    
    func categories(searchString: String?) async -> [EmojiCategory] {
        []
    }
    
    func frequentlyUsedSystemEmojis() -> [String] {
        []
    }
    
    func markEmojiAsFrequentlyUsed(_ emoji: String) {
        markedEmojis.append(emoji)
    }
    
    func markEmojiAsRecentlyUsed(_ emoji: String, shortcode: String?) async {
        recentEmojiContinuation.yield(.init(emoji: emoji, shortcode: shortcode))
    }
}
