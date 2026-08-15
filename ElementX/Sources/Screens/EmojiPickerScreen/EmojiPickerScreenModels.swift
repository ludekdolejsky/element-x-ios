//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

typealias EmojiPickerScreenContinuation = AsyncStream<EmojiPickerEmojiViewData>.Continuation

enum EmojiPickerScreenViewModelAction {
    case dismiss
}

struct EmojiPickerScreenViewState: BindableState {
    var categories: [EmojiPickerEmojiCategoryViewData]
    var selectedEmojis: Set<String>
}

enum EmojiPickerScreenViewAction {
    case search(searchString: String)
    case emojiTapped(emoji: EmojiPickerEmojiViewData)
    case dismiss
}

struct EmojiPickerEmojiCategoryViewData: Identifiable {
    let id: String
    let nameOverride: String?
    let emojis: [EmojiPickerEmojiViewData]
    
    var name: String {
        if let nameOverride {
            return nameOverride
        }
        
        switch id {
        case "people":
            return L10n.emojiPickerCategoryPeople
        case "nature":
            return L10n.emojiPickerCategoryNature
        case "foods":
            return L10n.emojiPickerCategoryFoods
        case "activity":
            return L10n.emojiPickerCategoryActivity
        case "places":
            return L10n.emojiPickerCategoryPlaces
        case "objects":
            return L10n.emojiPickerCategoryObjects
        case "symbols":
            return L10n.emojiPickerCategorySymbols
        case "flags":
            return L10n.emojiPickerCategoryFlags
        case EmojiCategory.frequentlyUsedCategoryIdentifier:
            return L10n.emojiPickerCategoryRecent
        default:
            return id
        }
    }
}

nonisolated struct EmojiPickerEmojiViewData: Equatable, Identifiable, Sendable {
    let id: String
    let value: String
    let label: String
    let customEmoji: CustomEmoji?
    
    var reactionKey: String {
        customEmoji?.imageURL.absoluteString ?? value
    }
}
