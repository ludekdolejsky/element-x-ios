//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated struct CustomEmoji: Equatable, Sendable {
    let shortcode: String
    let body: String
    let imageURL: URL
}

nonisolated struct EmojiItem: Equatable, Identifiable, Sendable {
    var id: String {
        guard let customEmoji else { return unicode }
        return "\(customEmoji.imageURL.absoluteString)#\(customEmoji.shortcode)"
    }
    
    var reactionKey: String {
        customEmoji?.imageURL.absoluteString ?? unicode
    }
    
    let label: String
    let unicode: String
    let keywords: [String]
    let shortcodes: [String]
    let customEmoji: CustomEmoji?
    
    init(label: String,
         unicode: String,
         keywords: [String],
         shortcodes: [String],
         customEmoji: CustomEmoji? = nil) {
        self.label = label
        self.unicode = unicode
        self.keywords = keywords
        self.shortcodes = shortcodes
        self.customEmoji = customEmoji
    }
}

nonisolated struct EmojiCategory: Equatable, Identifiable, Sendable {
    static let frequentlyUsedCategoryIdentifier = "io.element.elementx.frequently_used"
    
    let id: String
    let name: String?
    let emojis: [EmojiItem]
    
    init(id: String, name: String? = nil, emojis: [EmojiItem]) {
        self.id = id
        self.name = name
        self.emojis = emojis
    }
}

enum EmojiProviderState {
    case notLoaded
    case inProgress(Task<[EmojiCategory], Never>)
    case loaded([EmojiCategory])
}

protocol EmojiProviderProtocol {
    func categories(searchString: String?) async -> [EmojiCategory]
    func customEmojis() async -> [CustomEmoji]
    func cachedCustomEmojis() -> [CustomEmoji]
    func shouldRetryLoadingCategories() -> Bool
    
    func frequentlyUsedSystemEmojis() -> [String]
    func markEmojiAsFrequentlyUsed(_ emoji: String)
    func markEmojiAsRecentlyUsed(_ emoji: String, shortcode: String?) async
}

extension EmojiProviderProtocol {
    func customEmojis() async -> [CustomEmoji] {
        await categories(searchString: nil).flatMap(\.emojis).compactMap(\.customEmoji)
    }
    
    func cachedCustomEmojis() -> [CustomEmoji] {
        []
    }
    
    func shouldRetryLoadingCategories() -> Bool {
        false
    }
    
    func markEmojiAsRecentlyUsed(_ emoji: String, shortcode: String?) async {
        guard !emoji.hasPrefix("mxc://") else { return }
        markEmojiAsFrequentlyUsed(emoji)
    }
}
