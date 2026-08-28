//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct NitroRecentEmojiEntry: Codable, Equatable {
    let emoji: String
    var total: UInt64
    var shortcode: String?
}

@MainActor
protocol NitroRecentEmojiStoreProtocol: AnyObject, Sendable {
    var rankedEntries: [NitroRecentEmojiEntry] { get }
    func entries() async -> [NitroRecentEmojiEntry]
    func recordUsage(emoji: String, shortcode: String?) async
}

protocol NitroEmojiUsageRankingProvider: AnyObject {
    var recentEmojiUsageRanks: [String: Int] { get }
}

final class NitroRecentEmojiStore: NitroRecentEmojiStoreProtocol {
    typealias AccountDataProvider = (String) async -> Result<String?, ClientProxyError>
    typealias AccountDataWriter = (String, String) async -> Result<Void, ClientProxyError>
    
    private enum Constants {
        static let eventType = "m.recent_emoji"
        static let legacyEventType = "io.element.recent_emoji"
        static let storageLimit = 100
    }
    
    private struct AccountData: Codable {
        let recentEmoji: [NitroRecentEmojiEntry]
        
        enum CodingKeys: String, CodingKey {
            case recentEmoji = "recent_emoji"
        }
    }
    
    private struct LegacyAccountData: Decodable {
        let recentEmoji: [LegacyEntry]
        
        enum CodingKeys: String, CodingKey {
            case recentEmoji = "recent_emoji"
        }
    }
    
    private struct LegacyEntry: Decodable {
        let emoji: String
        let total: UInt64
        
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            emoji = try container.decode(String.self)
            total = try container.decode(UInt64.self)
        }
    }
    
    private struct AccountDataLoad {
        let content: String?
        let succeeded: Bool
    }
    
    private struct EntriesLoad {
        let entries: [NitroRecentEmojiEntry]
        let canPersist: Bool
    }
    
    private struct PendingUsage {
        var total: UInt64
        var shortcode: String?
    }
    
    private enum Operation {
        case load
        case recordUsage(emoji: String, shortcode: String?)
    }
    
    private let baseProvider: EmojiProviderProtocol
    private let accountDataProvider: AccountDataProvider
    private let accountDataWriter: AccountDataWriter
    
    private var baseEntries = [NitroRecentEmojiEntry]()
    private var cachedEntries = [NitroRecentEmojiEntry]()
    private var pendingUsage = [String: PendingUsage]()
    private var pendingUsageOrder = [String]()
    private var operationTask: Task<Void, Never>?
    private var operationGeneration = 0
    
    var rankedEntries: [NitroRecentEmojiEntry] {
        ranked(cachedEntries)
    }
    
    init(baseProvider: EmojiProviderProtocol,
         accountDataProvider: @escaping AccountDataProvider,
         accountDataWriter: @escaping AccountDataWriter) {
        self.baseProvider = baseProvider
        self.accountDataProvider = accountDataProvider
        self.accountDataWriter = accountDataWriter
    }
    
    func entries() async -> [NitroRecentEmojiEntry] {
        await enqueue(.load)
        return cachedEntries
    }
    
    func recordUsage(emoji: String, shortcode: String?) async {
        guard !emoji.isEmpty else { return }
        if !emoji.hasPrefix("mxc://") {
            baseProvider.markEmojiAsFrequentlyUsed(emoji)
        }
        
        await enqueue(.recordUsage(emoji: emoji, shortcode: shortcode))
    }
    
    private func enqueue(_ operation: Operation) async {
        let previousOperationTask = operationTask
        operationGeneration += 1
        let generation = operationGeneration
        let task = Task { [weak self] in
            await previousOperationTask?.value
            guard let self, !Task.isCancelled else { return }
            await perform(operation)
            if operationGeneration == generation {
                operationTask = nil
            }
        }
        operationTask = task
        await task.value
    }
    
    private func perform(_ operation: Operation) async {
        let loadedEntries = await loadEntries()
        switch operation {
        case .load:
            break
        case .recordUsage(let emoji, let shortcode):
            addPendingUsage(emoji: emoji, shortcode: shortcode)
            cachedEntries = entriesApplyingPendingUsage(to: baseEntries)
        }
        await flushPendingUsage(canPersist: loadedEntries.canPersist)
    }
    
    private func flushPendingUsage(canPersist: Bool) async {
        guard canPersist, !pendingUsage.isEmpty else { return }
        guard await persist(cachedEntries) else { return }
        baseEntries = cachedEntries
        pendingUsage.removeAll()
        pendingUsageOrder.removeAll()
    }
    
    private func loadEntries() async -> EntriesLoad {
        let stableLoad = await loadAccountData(eventType: Constants.eventType)
        let legacyLoad = await loadAccountData(eventType: Constants.legacyEventType)
        let stableEntries = stableLoad.succeeded ? decode(stableLoad.content) : nil
        let legacyEntries = legacyLoad.succeeded ? decodeLegacy(legacyLoad.content) : nil
        let localEntries = baseProvider.frequentlyUsedSystemEmojis().map {
            NitroRecentEmojiEntry(emoji: $0, total: 0, shortcode: nil)
        }
        let loadedEntries = merge(primary: stableEntries ?? [], secondary: legacyEntries ?? [])
        let entriesWithLocalFallback = merge(primary: loadedEntries, secondary: localEntries)
        baseEntries = Array(merge(primary: entriesWithLocalFallback, secondary: baseEntries).prefix(Constants.storageLimit))
        cachedEntries = entriesApplyingPendingUsage(to: baseEntries)
        return EntriesLoad(entries: cachedEntries,
                           canPersist: stableEntries != nil && legacyEntries != nil)
    }
    
    private func loadAccountData(eventType: String) async -> AccountDataLoad {
        switch await accountDataProvider(eventType) {
        case .success(let content):
            return AccountDataLoad(content: content, succeeded: true)
        case .failure(let error):
            MXLog.error("Failed loading recent emoji account data for \(eventType): \(error)")
            return AccountDataLoad(content: nil, succeeded: false)
        }
    }
    
    private func decode(_ content: String?) -> [NitroRecentEmojiEntry]? {
        guard let content else { return [] }
        guard let data = content.data(using: .utf8) else { return nil }
        
        do {
            return try JSONDecoder().decode(AccountData.self, from: data).recentEmoji
        } catch {
            MXLog.error("Failed decoding recent emoji account data")
            return nil
        }
    }
    
    private func decodeLegacy(_ content: String?) -> [NitroRecentEmojiEntry]? {
        guard let content else { return [] }
        guard let data = content.data(using: .utf8) else { return nil }
        
        do {
            return try JSONDecoder().decode(LegacyAccountData.self, from: data).recentEmoji.map {
                NitroRecentEmojiEntry(emoji: $0.emoji, total: $0.total, shortcode: nil)
            }
        } catch {
            MXLog.error("Failed decoding legacy recent emoji account data")
            return nil
        }
    }
    
    private func persist(_ entries: [NitroRecentEmojiEntry]) async -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(AccountData(recentEmoji: entries))
            guard let content = String(data: data, encoding: .utf8) else {
                MXLog.error("Failed encoding recent emoji account data")
                return false
            }
            
            switch await accountDataWriter(Constants.eventType, content) {
            case .success:
                return true
            case .failure(let error):
                MXLog.error("Failed saving recent emoji account data: \(error)")
                return false
            }
        } catch {
            MXLog.error("Failed encoding recent emoji account data")
            return false
        }
    }
    
    private func addPendingUsage(emoji: String, shortcode: String?) {
        var usage = pendingUsage[emoji] ?? PendingUsage(total: 0, shortcode: nil)
        usage.total = usage.total == UInt64.max ? UInt64.max : usage.total + 1
        usage.shortcode = shortcode ?? usage.shortcode
        pendingUsage[emoji] = usage
        pendingUsageOrder.removeAll { $0 == emoji }
        pendingUsageOrder.insert(emoji, at: 0)
        if pendingUsageOrder.count > Constants.storageLimit,
           let removedEmoji = pendingUsageOrder.popLast() {
            pendingUsage[removedEmoji] = nil
        }
    }
    
    private func entriesApplyingPendingUsage(to entries: [NitroRecentEmojiEntry]) -> [NitroRecentEmojiEntry] {
        var updatedEntries = entries
        for emoji in pendingUsageOrder.reversed() {
            guard let usage = pendingUsage[emoji] else { continue }
            if let index = updatedEntries.firstIndex(where: { $0.emoji == emoji }) {
                var entry = updatedEntries.remove(at: index)
                entry.total = adding(usage.total, to: entry.total)
                entry.shortcode = usage.shortcode ?? entry.shortcode
                updatedEntries.insert(entry, at: 0)
            } else {
                updatedEntries.insert(.init(emoji: emoji,
                                            total: usage.total,
                                            shortcode: usage.shortcode), at: 0)
            }
        }
        return Array(updatedEntries.prefix(Constants.storageLimit))
    }
    
    private func adding(_ increment: UInt64, to total: UInt64) -> UInt64 {
        let (result, overflow) = total.addingReportingOverflow(increment)
        return overflow ? UInt64.max : result
    }
    
    private func merge(primary: [NitroRecentEmojiEntry], secondary: [NitroRecentEmojiEntry]) -> [NitroRecentEmojiEntry] {
        var merged = primary.filter { !$0.emoji.isEmpty }
        for entry in secondary where !entry.emoji.isEmpty {
            guard let index = merged.firstIndex(where: { $0.emoji == entry.emoji }) else {
                merged.append(entry)
                continue
            }
            
            if entry.total > merged[index].total {
                var replacement = entry
                replacement.shortcode = entry.shortcode ?? merged[index].shortcode
                merged[index] = replacement
            } else if merged[index].shortcode == nil {
                merged[index].shortcode = entry.shortcode
            }
        }
        return merged
    }
    
    private func ranked(_ entries: [NitroRecentEmojiEntry]) -> [NitroRecentEmojiEntry] {
        entries.enumerated().sorted { lhs, rhs in
            if lhs.element.total != rhs.element.total {
                return lhs.element.total > rhs.element.total
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }
}
