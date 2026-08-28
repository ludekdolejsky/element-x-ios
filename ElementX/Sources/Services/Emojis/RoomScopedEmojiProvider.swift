//
// Copyright 2026 Element Creations Ltd.
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated struct RoomStateEventProxy: Equatable, Sendable {
    let roomID: String
    let type: String
    let stateKey: String
    let content: String
}

final class RoomScopedEmojiProvider: EmojiProviderProtocol, NitroEmojiUsageRankingProvider {
    private enum Constants {
        static let stableRoomImagePackEventType = "m.room.image_pack"
        static let legacyRoomImagePackEventType = "im.ponies.room_emotes"
        static let stableGlobalImagePackEventType = "m.image_pack.rooms"
        static let legacyGlobalImagePackEventType = "im.ponies.emote_rooms"
        static let emoticonUsage = "emoticon"
        static let customCategoryPrefix = "io.element.elementx.custom."
        static let cacheLifetime: TimeInterval = 5 * 60
        static let failureRetryDelay: TimeInterval = 30
        static let maximumSpaceHierarchyDepth = 5
        static let maximumGlobalPackRoomCount = 64
        static let maximumConcurrentRoomStateRequests = 4
        static let globalPackPriority = 0
        static let currentRoomPackPriority = 1
        static let recentEmojiDisplayLimit = 40
    }
    
    private struct PackMeta: Decodable {
        let displayName: String?
        let usage: [String]?
        
        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case usage
        }
    }
    
    private struct PackImage: Decodable {
        let url: String?
        let body: String?
        let usage: [String]?
    }
    
    private struct PackContent: Decodable {
        let images: [String: PackImage]
        let pack: PackMeta?
    }
    
    private struct GlobalPackRoomsContent: Decodable {
        let rooms: [String: [String: JSONValue]]
    }
    
    private struct RoomNameContent: Decodable {
        let name: String
    }
    
    private struct SpaceParentContent: Decodable {
        let canonical: Bool?
    }
    
    private struct RoomMembershipContent: Decodable {
        let membership: String
    }
    
    private struct PackSource {
        let event: RoomStateEventProxy
        let roomName: String?
        let priority: Int
        let isGlobal: Bool
    }
    
    private struct CategorizedPack {
        let priority: Int
        let isGlobal: Bool
        let category: EmojiCategory
    }
    
    private struct PackIdentity: Hashable {
        let roomID: String
        let stateKey: String
    }
    
    private struct CustomCategories {
        static let empty = CustomCategories(contextual: [], global: [])
        
        let contextual: [EmojiCategory]
        let global: [EmojiCategory]
        
        var all: [EmojiCategory] {
            contextual + global
        }
    }
    
    private struct CacheEntry {
        let timestamp: Date
        let categories: CustomCategories
    }
    
    private enum JSONValue: Decodable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
            }
        }
    }
    
    typealias AccountDataProvider = (String) async -> Result<String?, ClientProxyError>
    typealias RoomStateProvider = (String) async -> Result<[RoomStateEventProxy], ClientProxyError>
    
    private let roomID: String
    private let userID: String
    private let baseProvider: EmojiProviderProtocol
    private let accountDataProvider: AccountDataProvider
    private let recentEmojiStore: NitroRecentEmojiStoreProtocol
    private let roomStateProvider: RoomStateProvider
    private let now: () -> Date
    
    private var cacheEntry: CacheEntry?
    private var loadingTask: Task<CustomCategories, Never>?
    private var lastCustomEmojiLoadFailed = false
    private var lastLoadAttemptDate: Date?
    
    init(roomID: String,
         userID: String,
         baseProvider: EmojiProviderProtocol,
         accountDataProvider: @escaping AccountDataProvider,
         recentEmojiStore: NitroRecentEmojiStoreProtocol,
         roomStateProvider: @escaping RoomStateProvider,
         now: @escaping () -> Date = Date.init) {
        self.roomID = roomID
        self.userID = userID
        self.baseProvider = baseProvider
        self.accountDataProvider = accountDataProvider
        self.recentEmojiStore = recentEmojiStore
        self.roomStateProvider = roomStateProvider
        self.now = now
    }
    
    func categories(searchString: String?) async -> [EmojiCategory] {
        async let customCategories = loadCustomCategories()
        async let baseCategories = loadBaseCategories()
        async let recentEntries = recentEmojiStore.entries()
        let (loadedCustomCategories, loadedBaseCategories, loadedRecentEntries) = await (customCategories, baseCategories, recentEntries)
        let standardCategories = loadedBaseCategories.filter { $0.id != EmojiCategory.frequentlyUsedCategoryIdentifier }
        let recentCategory = buildRecentCategory(entries: loadedRecentEntries,
                                                 standardCategories: standardCategories,
                                                 customCategories: loadedCustomCategories.all)
        let categories = [recentCategory].compactMap { $0 }
            + loadedCustomCategories.contextual
            + standardCategories
            + loadedCustomCategories.global
        
        guard let searchString, !searchString.isEmpty else {
            return categories
        }
        
        return search(searchString: searchString, categories: categories)
    }
    
    func frequentlyUsedSystemEmojis() -> [String] {
        baseProvider.frequentlyUsedSystemEmojis()
    }
    
    var recentEmojiUsageRanks: [String: Int] {
        Dictionary(recentEmojiStore.rankedEntries.enumerated().map { ($0.element.emoji, $0.offset) },
                   uniquingKeysWith: min)
    }
    
    func customEmojis() async -> [CustomEmoji] {
        await loadCustomCategories().all.flatMap(\.emojis).compactMap(\.customEmoji)
    }
    
    func cachedCustomEmojis() -> [CustomEmoji] {
        cacheEntry?.categories.all.flatMap(\.emojis).compactMap(\.customEmoji) ?? []
    }
    
    func shouldRetryLoadingCategories() -> Bool {
        lastCustomEmojiLoadFailed
    }
    
    func markEmojiAsFrequentlyUsed(_ emoji: String) {
        guard !emoji.hasPrefix("mxc://") else { return }
        baseProvider.markEmojiAsFrequentlyUsed(emoji)
    }
    
    func markEmojiAsRecentlyUsed(_ emoji: String, shortcode: String?) async {
        await recentEmojiStore.recordUsage(emoji: emoji, shortcode: shortcode)
    }
    
    private func loadBaseCategories() async -> [EmojiCategory] {
        await baseProvider.categories(searchString: nil)
    }
    
    private func loadCustomCategories() async -> CustomCategories {
        let currentDate = now()
        if let cacheEntry,
           currentDate.timeIntervalSince(cacheEntry.timestamp) < Constants.cacheLifetime {
            return cacheEntry.categories
        }
        
        if lastCustomEmojiLoadFailed,
           let lastLoadAttemptDate,
           currentDate.timeIntervalSince(lastLoadAttemptDate) < Constants.failureRetryDelay {
            return cacheEntry?.categories ?? .empty
        }
        
        if let loadingTask {
            let categories = await loadingTask.value
            return lastCustomEmojiLoadFailed ? cacheEntry?.categories ?? categories : categories
        }
        
        let task = Task { await fetchCustomCategories() }
        loadingTask = task
        let categories = await task.value
        loadingTask = nil
        lastLoadAttemptDate = now()
        if lastCustomEmojiLoadFailed {
            return cacheEntry?.categories ?? categories
        }
        cacheEntry = .init(timestamp: now(), categories: categories)
        return categories
    }
    
    private func fetchCustomCategories() async -> CustomCategories {
        lastCustomEmojiLoadFailed = false
        async let currentRoomEventsTask = loadRoomState(roomID: roomID)
        async let globalSourcesTask = globalPackSources()
        let currentRoomEvents = await currentRoomEventsTask
        
        var seenPacks = Set<PackIdentity>()
        var sources = uniquePackSources(in: currentRoomEvents,
                                        roomName: roomName(from: currentRoomEvents),
                                        priority: Constants.currentRoomPackPriority,
                                        isGlobal: false,
                                        seenPacks: &seenPacks)
        sources += await parentSpacePackSources(childRoomEvents: currentRoomEvents,
                                                seenPacks: &seenPacks)
        sources += await globalSourcesTask
        sources = removingDuplicatePacks(from: sources)
        
        let categories = sources
            .compactMap(buildCategory)
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                let lhsName = lhs.category.name ?? lhs.category.id
                let rhsName = rhs.category.name ?? rhs.category.id
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
        let deduplicatedCategories = removingDuplicateShortcodes(from: categories)
        return .init(contextual: deduplicatedCategories.filter { !$0.isGlobal }.map(\.category),
                     global: deduplicatedCategories.filter(\.isGlobal).map(\.category))
    }
    
    private func globalPackSources() async -> [PackSource] {
        async let stableContent = loadAccountData(eventType: Constants.stableGlobalImagePackEventType)
        async let legacyContent = loadAccountData(eventType: Constants.legacyGlobalImagePackEventType)
        let accountData = await [(Constants.stableGlobalImagePackEventType, stableContent),
                                 (Constants.legacyGlobalImagePackEventType, legacyContent)]
        let allReferencedRoomIDs = Set(accountData.flatMap { _, content in
            content.flatMap { decode(GlobalPackRoomsContent.self, from: $0).map { Array($0.rooms.keys) } } ?? []
        })
        let referencedRoomIDs = Array(allReferencedRoomIDs.sorted().prefix(Constants.maximumGlobalPackRoomCount))
        if allReferencedRoomIDs.count > referencedRoomIDs.count {
            MXLog.error("Ignoring global image-pack rooms above the supported limit of \(Constants.maximumGlobalPackRoomCount)")
        }
        let roomStateCache = await loadRoomStates(roomIDs: referencedRoomIDs)
        
        var sources = [PackSource]()
        var seenPacks = Set<PackIdentity>()
        
        for (_, content) in accountData {
            guard let content,
                  let references = decode(GlobalPackRoomsContent.self, from: content)?.rooms else {
                continue
            }
            
            for referencedRoomID in references.keys.sorted() {
                guard let referencedStateKeys = references[referencedRoomID] else { continue }
                
                let events = roomStateCache[referencedRoomID] ?? []
                let allowedStateKeys: Set<String>
                if referencedStateKeys.isEmpty {
                    allowedStateKeys = Set(events.filter(isImagePackEvent).map(\.stateKey))
                } else {
                    allowedStateKeys = Set(referencedStateKeys.keys)
                }
                
                sources += uniquePackSources(in: events,
                                             roomName: roomName(from: events),
                                             priority: Constants.globalPackPriority,
                                             isGlobal: true,
                                             allowedStateKeys: allowedStateKeys,
                                             seenPacks: &seenPacks)
            }
        }
        
        return sources
    }
    
    private func loadRoomStates(roomIDs: [String]) async -> [String: [RoomStateEventProxy]] {
        await withTaskGroup(of: (String, [RoomStateEventProxy]).self) { group in
            var roomIDIterator = roomIDs.makeIterator()
            for _ in 0..<Constants.maximumConcurrentRoomStateRequests {
                guard let roomID = roomIDIterator.next() else { break }
                group.addTask {
                    await (roomID, self.loadRoomState(roomID: roomID, isOptional: true))
                }
            }
            
            var roomStates = [String: [RoomStateEventProxy]]()
            while let (roomID, events) = await group.next() {
                roomStates[roomID] = events
                guard !Task.isCancelled,
                      let nextRoomID = roomIDIterator.next() else {
                    continue
                }
                group.addTask {
                    await (nextRoomID, self.loadRoomState(roomID: nextRoomID, isOptional: true))
                }
            }
            return roomStates
        }
    }
    
    private func parentSpacePackSources(childRoomEvents: [RoomStateEventProxy],
                                        seenPacks: inout Set<PackIdentity>) async -> [PackSource] {
        var sources = [PackSource]()
        var childRoomEvents = childRoomEvents
        var roomStateCache = [roomID: childRoomEvents]
        var visitedRoomIDs: Set<String> = [roomID]
        for depth in 0..<Constants.maximumSpaceHierarchyDepth {
            guard let spaceID = canonicalSpaceID(from: childRoomEvents),
                  visitedRoomIDs.insert(spaceID).inserted else {
                break
            }
            
            let spaceEvents = await roomState(roomID: spaceID, cache: &roomStateCache, isOptional: true)
            guard isJoined(roomEvents: spaceEvents) else { break }
            
            sources += uniquePackSources(in: spaceEvents,
                                         roomName: roomName(from: spaceEvents),
                                         priority: depth + 2,
                                         isGlobal: false,
                                         seenPacks: &seenPacks)
            childRoomEvents = spaceEvents
        }
        
        return sources
    }
    
    private func roomState(roomID: String,
                           cache: inout [String: [RoomStateEventProxy]],
                           isOptional: Bool) async -> [RoomStateEventProxy] {
        if let events = cache[roomID] {
            return events
        }
        
        let events = await loadRoomState(roomID: roomID, isOptional: isOptional)
        cache[roomID] = events
        return events
    }
    
    private func uniquePackSources(in events: [RoomStateEventProxy],
                                   roomName: String?,
                                   priority: Int,
                                   isGlobal: Bool,
                                   allowedStateKeys: Set<String>? = nil,
                                   seenPacks: inout Set<PackIdentity>) -> [PackSource] {
        imagePackEvents(in: events).compactMap { event in
            guard allowedStateKeys?.contains(event.stateKey) ?? true else { return nil }
            let identity = PackIdentity(roomID: event.roomID, stateKey: event.stateKey)
            guard seenPacks.insert(identity).inserted else { return nil }
            return PackSource(event: event, roomName: roomName, priority: priority, isGlobal: isGlobal)
        }
    }
    
    private func removingDuplicatePacks(from sources: [PackSource]) -> [PackSource] {
        var seenPacks = Set<PackIdentity>()
        return sources.filter { source in
            seenPacks.insert(.init(roomID: source.event.roomID, stateKey: source.event.stateKey)).inserted
        }
    }
    
    private func loadAccountData(eventType: String) async -> String? {
        switch await accountDataProvider(eventType) {
        case .success(let content):
            return content
        case .failure(let error):
            lastCustomEmojiLoadFailed = true
            MXLog.error("Failed loading image-pack account data for \(eventType): \(error)")
            return nil
        }
    }
    
    private func loadRoomState(roomID: String, isOptional: Bool = false) async -> [RoomStateEventProxy] {
        guard !Task.isCancelled else { return [] }
        let result = await roomStateProvider(roomID)
        guard !Task.isCancelled else { return [] }
        switch result {
        case .success(let events):
            return events
        case .failure(let error):
            if isOptional, case .forbiddenAccess = error {
                MXLog.info("Skipping inaccessible image-pack room state for \(roomID)")
                return []
            }
            lastCustomEmojiLoadFailed = true
            MXLog.error("Failed loading image-pack room state for \(roomID): \(error)")
            return []
        }
    }
    
    private func buildCategory(source: PackSource) -> CategorizedPack? {
        guard let content = decode(PackContent.self, from: source.event.content),
              isEmoticonUsage(content.pack?.usage) else {
            return nil
        }
        
        let packName = content.pack?.displayName ?? source.roomName ?? source.event.stateKey.ifEmpty(source.event.roomID)
        let items = content.images.compactMap { shortcode, image -> EmojiItem? in
            guard let urlString = image.url,
                  let imageURL = validMXCURL(from: urlString),
                  isEmoticonUsage(image.usage) else {
                return nil
            }
            
            let body = image.body?.ifEmpty(shortcode) ?? shortcode
            let customEmoji = CustomEmoji(shortcode: shortcode, body: body, imageURL: imageURL)
            return EmojiItem(label: body,
                             unicode: ":\(shortcode):",
                             keywords: [body, shortcode, packName],
                             shortcodes: [shortcode],
                             customEmoji: customEmoji)
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        
        guard !items.isEmpty else { return nil }
        
        let categoryID = Constants.customCategoryPrefix + "\(source.event.roomID)|\(source.event.stateKey)"
        return CategorizedPack(priority: source.priority,
                               isGlobal: source.isGlobal,
                               category: EmojiCategory(id: categoryID, name: packName, emojis: items))
    }
    
    private func buildRecentCategory(entries: [NitroRecentEmojiEntry],
                                     standardCategories: [EmojiCategory],
                                     customCategories: [EmojiCategory]) -> EmojiCategory? {
        let standardEmojis = standardCategories.flatMap(\.emojis)
        let customEmojis = customCategories.flatMap(\.emojis)
        let sortedEntries = entries.enumerated().sorted { lhs, rhs in
            if lhs.element.total != rhs.element.total {
                return lhs.element.total > rhs.element.total
            }
            return lhs.offset < rhs.offset
        }
        
        var seenEmojiIDs = Set<String>()
        let emojis = sortedEntries.compactMap { _, entry -> EmojiItem? in
            let item: EmojiItem?
            if entry.emoji.hasPrefix("mxc://") {
                if let shortcode = entry.shortcode, !shortcode.isEmpty {
                    item = customEmojis.first {
                        $0.reactionKey == entry.emoji && $0.customEmoji?.shortcode == shortcode
                    }
                } else {
                    item = customEmojis.first { $0.reactionKey == entry.emoji }
                }
            } else {
                item = standardEmojis.first { $0.unicode == entry.emoji }
            }
            
            guard let item, seenEmojiIDs.insert(item.id).inserted else { return nil }
            return item
        }
        .prefix(Constants.recentEmojiDisplayLimit)
        
        guard !emojis.isEmpty else { return nil }
        return EmojiCategory(id: EmojiCategory.frequentlyUsedCategoryIdentifier, emojis: Array(emojis))
    }
    
    private func search(searchString: String, categories: [EmojiCategory]) -> [EmojiCategory] {
        categories.compactMap { category in
            let emojis = category.emojis.filter { emoji in
                let values = [emoji.label, emoji.unicode, emoji.reactionKey] + emoji.shortcodes + emoji.keywords
                return values.joined(separator: " ").range(of: searchString, options: .caseInsensitive) != nil
            }
            return emojis.isEmpty ? nil : EmojiCategory(id: category.id, name: category.name, emojis: emojis)
        }
    }
    
    private func removingDuplicateShortcodes(from categories: [CategorizedPack]) -> [CategorizedPack] {
        var seenShortcodes = Set<String>()
        return categories.compactMap { categorized in
            let emojis = categorized.category.emojis.filter { emoji in
                guard let shortcode = emoji.customEmoji?.shortcode else { return true }
                return seenShortcodes.insert(shortcode).inserted
            }
            guard !emojis.isEmpty else { return nil }
            return CategorizedPack(priority: categorized.priority,
                                   isGlobal: categorized.isGlobal,
                                   category: EmojiCategory(id: categorized.category.id, name: categorized.category.name, emojis: emojis))
        }
    }
    
    private func roomName(from events: [RoomStateEventProxy]) -> String? {
        guard let event = events.first(where: { $0.type == "m.room.name" && $0.stateKey.isEmpty }) else {
            return nil
        }
        return decode(RoomNameContent.self, from: event.content)?.name
    }
    
    private func canonicalSpaceID(from events: [RoomStateEventProxy]) -> String? {
        events
            .filter { event in
                guard event.type == "m.space.parent",
                      let content = decode(SpaceParentContent.self, from: event.content) else {
                    return false
                }
                return content.canonical == true
            }
            .map(\.stateKey)
            .sorted()
            .first
    }
    
    private func isJoined(roomEvents: [RoomStateEventProxy]) -> Bool {
        guard let membershipEvent = roomEvents.first(where: { $0.type == "m.room.member" && $0.stateKey == userID }),
              let membership = decode(RoomMembershipContent.self, from: membershipEvent.content) else {
            return false
        }
        return membership.membership == "join"
    }
    
    private func isImagePackEvent(_ event: RoomStateEventProxy) -> Bool {
        event.type == Constants.stableRoomImagePackEventType || event.type == Constants.legacyRoomImagePackEventType
    }
    
    private func imagePackEvents(in events: [RoomStateEventProxy]) -> [RoomStateEventProxy] {
        events
            .filter(isImagePackEvent)
            .sorted { lhs, rhs in
                if lhs.stateKey != rhs.stateKey {
                    return lhs.stateKey < rhs.stateKey
                }
                return lhs.type == Constants.stableRoomImagePackEventType && rhs.type != Constants.stableRoomImagePackEventType
            }
    }
    
    private func isEmoticonUsage(_ usage: [String]?) -> Bool {
        usage?.isEmpty != false || usage?.contains(Constants.emoticonUsage) == true
    }
    
    private func validMXCURL(from string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "mxc", url.host != nil else {
            return nil
        }
        return url
    }
    
    private func decode<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            MXLog.error("Failed decoding image-pack content: \(error)")
            return nil
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
