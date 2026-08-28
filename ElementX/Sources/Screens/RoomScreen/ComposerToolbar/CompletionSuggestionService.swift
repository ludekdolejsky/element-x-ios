//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

private enum SuggestionTriggerRegex {
    /// Matches any string of characters after an @ or # that is not a whitespace
    static let atOrHash = /[@#]\S*/
    /// Matches an incomplete emoji shortcode. Context validation is performed separately.
    static let colon = /:[A-Za-z0-9_+-]*/
    
    static let at: Character = "@"
    static let hash: Character = "#"
}

final class CompletionSuggestionService: CompletionSuggestionServiceProtocol {
    private enum Constants {
        static let emojiItemsCacheLifetime: TimeInterval = 5 * 60
        static let emojiItemsRetryDelay: TimeInterval = 30
    }
    
    private let roomProxy: JoinedRoomProxyProtocol
    private let emojiProvider: EmojiProviderProtocol?
    private let now: () -> Date
    private var canMentionAllUsers = false
    private var isLoadingEmojiItems = false
    private var lastEmojiItemsLoadDate: Date?
    private var lastEmojiItemsLoadFailed = false
    
    private(set) var suggestionsPublisher: AnyPublisher<[SuggestionItem], Never> = Empty().eraseToAnyPublisher()
    
    private let suggestionTriggerSubject = CurrentValueSubject<SuggestionTrigger?, Never>(nil)
    private let emojiItemsSubject = CurrentValueSubject<[EmojiItem], Never>([])
    
    private var cancellables = Set<AnyCancellable>()
    
    init(roomProxy: JoinedRoomProxyProtocol,
         roomListPublisher: AnyPublisher<[RoomSummary], Never>,
         emojiProvider: EmojiProviderProtocol? = nil,
         now: @escaping () -> Date = Date.init) {
        self.roomProxy = roomProxy
        self.emojiProvider = emojiProvider
        self.now = now
        
        suggestionsPublisher = suggestionTriggerSubject
            .combineLatest(roomProxy.membersPublisher, roomListPublisher)
            .combineLatest(emojiItemsSubject)
            .map { [weak self, ownUserID = roomProxy.ownUserID] triggerAndRoomData, emojiItems -> [SuggestionItem] in
                let (suggestionTrigger, members, roomSummaries) = triggerAndRoomData
                guard let self,
                      let suggestionTrigger else {
                    return []
                }
                
                switch suggestionTrigger.type {
                case .user:
                    return membersSuggestions(suggestionTrigger: suggestionTrigger, members: members, ownUserID: ownUserID)
                case .room:
                    return roomSuggestions(suggestionTrigger: suggestionTrigger, roomSummaries: roomSummaries)
                case .emoji:
                    return emojiSuggestions(suggestionTrigger: suggestionTrigger,
                                            emojiItems: emojiItems)
                }
            }
            // We only debounce if the suggestion is nil
            .debounceAndRemoveDuplicates(on: DispatchQueue.main) { [weak self] _ in
                self?.suggestionTriggerSubject.value != nil ? .milliseconds(500) : .milliseconds(0)
            }
        
        roomProxy.infoPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] roomInfo in
                self?.updateRoomInfo(roomInfo)
            }
            .store(in: &cancellables)
        
        updateRoomInfo(roomProxy.infoPublisher.value)
    }
    
    func processTextMessage(_ textMessage: String, selectedRange: NSRange) {
        setSuggestionTrigger(detectTriggerInText(textMessage, selectedRange: selectedRange))
    }
    
    func setSuggestionTrigger(_ suggestionTrigger: SuggestionTrigger?) {
        suggestionTriggerSubject.value = suggestionTrigger
        if suggestionTrigger?.type == .emoji {
            loadEmojiItemsIfNeeded()
        }
    }
    
    // MARK: - Private
    
    private func updateRoomInfo(_ roomInfo: RoomInfoProxyProtocol) {
        if let powerLevels = roomInfo.powerLevels {
            canMentionAllUsers = powerLevels.canOwnUserTriggerRoomNotification()
        }
    }
    
    private func membersSuggestions(suggestionTrigger: SuggestionTrigger,
                                    members: [RoomMemberProxyProtocol],
                                    ownUserID: String) -> [SuggestionItem] {
        var membersSuggestion = members
            .compactMap { member -> SuggestionItem? in
                guard member.userID != ownUserID,
                      member.membership == .join,
                      Self.shouldIncludeMember(userID: member.userID, displayName: member.displayName, searchText: suggestionTrigger.text) else {
                    return nil
                }
                return .init(suggestionType: .user(.init(id: member.userID, displayName: member.displayName, avatarURL: member.avatarURL, status: member.status)),
                             range: suggestionTrigger.range, rawSuggestionText: suggestionTrigger.text)
            }
        
        if canMentionAllUsers,
           !roomProxy.infoPublisher.value.isDM,
           Self.shouldIncludeMember(userID: PillUtilities.atRoom, displayName: PillUtilities.everyone, searchText: suggestionTrigger.text) {
            membersSuggestion
                .insert(SuggestionItem(suggestionType: .allUsers(roomProxy.details.avatar), range: suggestionTrigger.range, rawSuggestionText: suggestionTrigger.text), at: 0)
        }
        
        return membersSuggestion
    }
    
    private func roomSuggestions(suggestionTrigger: SuggestionTrigger,
                                 roomSummaries: [RoomSummary]) -> [SuggestionItem] {
        roomSummaries
            .compactMap { roomSummary -> SuggestionItem? in
                guard let canonicalAlias = roomSummary.canonicalAlias,
                      Self.shouldIncludeRoom(roomName: roomSummary.name, roomAlias: canonicalAlias, searchText: suggestionTrigger.text) else {
                    return nil
                }
                
                return .init(suggestionType: .room(.init(id: roomSummary.id,
                                                         canonicalAlias: canonicalAlias,
                                                         name: roomSummary.name,
                                                         avatar: roomSummary.avatar)),
                             range: suggestionTrigger.range, rawSuggestionText: suggestionTrigger.text)
            }
    }
    
    private func emojiSuggestions(suggestionTrigger: SuggestionTrigger,
                                  emojiItems: [EmojiItem]) -> [SuggestionItem] {
        let matchingItems = emojiItems.filter { Self.shouldIncludeEmoji($0, searchText: suggestionTrigger.text) }
        let usageRanks = (emojiProvider as? NitroEmojiUsageRankingProvider)?.recentEmojiUsageRanks ?? [:]
        let orderedItems = matchingItems.sorted {
            Self.shouldOrderEmoji($0,
                                  before: $1,
                                  searchText: suggestionTrigger.text,
                                  usageRanks: usageRanks)
        }
        return orderedItems
            .prefix(50)
            .map {
                SuggestionItem(suggestionType: .emoji($0),
                               range: suggestionTrigger.range,
                               rawSuggestionText: suggestionTrigger.text)
            }
    }
    
    private func loadEmojiItemsIfNeeded() {
        guard let emojiProvider, !isLoadingEmojiItems, shouldLoadEmojiItems else { return }
        isLoadingEmojiItems = true
        
        Task { @MainActor [weak self] in
            let categories = await emojiProvider.categories(searchString: nil)
            guard let self else { return }
            isLoadingEmojiItems = false
            lastEmojiItemsLoadDate = now()
            lastEmojiItemsLoadFailed = emojiProvider.shouldRetryLoadingCategories()
            var seen = Set<String>()
            let items = categories
                .flatMap(\.emojis)
                .filter { emoji in
                    let key = emoji.customEmoji.map { "custom:\($0.shortcode)" } ?? "system:\(emoji.unicode)"
                    return seen.insert(key).inserted
                }
            if !lastEmojiItemsLoadFailed || emojiItemsSubject.value.isEmpty {
                emojiItemsSubject.send(items)
            }
        }
    }
    
    private var shouldLoadEmojiItems: Bool {
        guard let lastEmojiItemsLoadDate else { return true }
        let lifetime = lastEmojiItemsLoadFailed
            ? Constants.emojiItemsRetryDelay
            : Constants.emojiItemsCacheLifetime
        return now().timeIntervalSince(lastEmojiItemsLoadDate) >= lifetime
    }
    
    private func detectTriggerInText(_ text: String, selectedRange: NSRange) -> SuggestionTrigger? {
        let matches = text.matches(of: SuggestionTriggerRegex.atOrHash)
        let match = matches.first { matchResult in
            let lowerBound = matchResult.range.lowerBound.utf16Offset(in: matchResult.base)
            let upperBound = matchResult.range.upperBound.utf16Offset(in: matchResult.base)
            return selectedRange.location >= lowerBound
                && selectedRange.location <= upperBound
                && selectedRange.length <= upperBound - lowerBound
        }
        
        guard let match else {
            return detectColonTriggerInText(text, selectedRange: selectedRange)
        }
        
        var suggestionText = String(text[match.range])
        let firstChar = suggestionText.removeFirst()
        
        switch firstChar {
        case SuggestionTriggerRegex.at:
            return .init(type: .user, text: suggestionText, range: NSRange(match.range, in: text))
        case SuggestionTriggerRegex.hash:
            return .init(type: .room, text: suggestionText, range: NSRange(match.range, in: text))
        default:
            return nil
        }
    }
    
    private static func shouldIncludeMember(userID: String, displayName: String?, searchText: String) -> Bool {
        // If the search text is empty give back all the results
        guard !searchText.isEmpty else {
            return true
        }
        let containedInUserID = userID.localizedStandardContains(searchText)
        
        let containedInDisplayName: Bool
        if let displayName {
            containedInDisplayName = displayName.localizedStandardContains(searchText)
        } else {
            containedInDisplayName = false
        }
        
        return containedInUserID || containedInDisplayName
    }
    
    private static func shouldIncludeRoom(roomName: String, roomAlias: String, searchText: String) -> Bool {
        // If the search text is empty give back all the results
        guard !searchText.isEmpty else {
            return true
        }
        return roomName.localizedStandardContains(searchText) || roomAlias.localizedStandardContains(searchText)
    }
    
    private static func shouldIncludeEmoji(_ emoji: EmojiItem, searchText: String) -> Bool {
        guard !searchText.isEmpty else { return true }
        
        return ([emoji.label] + emoji.shortcodes + emoji.keywords)
            .contains { $0.localizedStandardContains(searchText) }
    }
    
    private static func emojiSortKey(_ emoji: EmojiItem, searchText: String) -> String {
        let shortcode = emoji.shortcodes.first ?? emoji.label
        let rank: Int
        if shortcode.caseInsensitiveCompare(searchText) == .orderedSame {
            rank = 0
        } else if shortcode.lowercased().hasPrefix(searchText.lowercased()) {
            rank = 1
        } else {
            rank = 2
        }
        let customRank = emoji.customEmoji == nil ? 1 : 0
        return "\(rank)-\(customRank)-\(shortcode.lowercased())"
    }
    
    private static func shouldOrderEmoji(_ lhs: EmojiItem,
                                         before rhs: EmojiItem,
                                         searchText: String,
                                         usageRanks: [String: Int]) -> Bool {
        let lhsExactMatch = lhs.shortcodes.contains { $0.caseInsensitiveCompare(searchText) == .orderedSame }
        let rhsExactMatch = rhs.shortcodes.contains { $0.caseInsensitiveCompare(searchText) == .orderedSame }
        if lhsExactMatch != rhsExactMatch {
            return lhsExactMatch
        }
        
        let lhsUsageRank = usageRanks[lhs.reactionKey] ?? Int.max
        let rhsUsageRank = usageRanks[rhs.reactionKey] ?? Int.max
        if lhsUsageRank != rhsUsageRank {
            return lhsUsageRank < rhsUsageRank
        }
        
        return emojiSortKey(lhs, searchText: searchText) < emojiSortKey(rhs, searchText: searchText)
    }
    
    private func detectColonTriggerInText(_ text: String, selectedRange: NSRange) -> SuggestionTrigger? {
        text.matches(of: SuggestionTriggerRegex.colon)
            .first { matchResult in
                let lowerBound = matchResult.range.lowerBound.utf16Offset(in: matchResult.base)
                let upperBound = matchResult.range.upperBound.utf16Offset(in: matchResult.base)
                let startsAtBoundary: Bool
                if matchResult.range.lowerBound == text.startIndex {
                    startsAtBoundary = true
                } else {
                    let previousCharacter = text[text.index(before: matchResult.range.lowerBound)]
                    startsAtBoundary = previousCharacter.isWhitespace
                        || (!previousCharacter.isLetter && !previousCharacter.isNumber && previousCharacter != "_" && previousCharacter != ":")
                }
                return startsAtBoundary
                    && selectedRange.location >= lowerBound
                    && selectedRange.location <= upperBound
                    && selectedRange.length <= upperBound - lowerBound
            }
            .map { matchResult in
                var suggestionText = String(text[matchResult.range])
                suggestionText.removeFirst()
                return SuggestionTrigger(type: .emoji,
                                         text: suggestionText,
                                         range: NSRange(matchResult.range, in: text))
            }
    }
}

extension PillUtilities {
    static var everyone: String {
        L10n.commonEveryone
    }
}
