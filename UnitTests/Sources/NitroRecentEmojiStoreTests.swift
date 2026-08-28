//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

@MainActor
struct NitroRecentEmojiStoreTests {
    @Test
    func mergesStableLegacyAndLocalEntries() async {
        let baseProvider = RecentStoreTestEmojiProvider(frequentlyUsedEmojis: ["❤️"])
        let store = NitroRecentEmojiStore(baseProvider: baseProvider,
                                          accountDataProvider: { eventType in
                                              switch eventType {
                                              case "m.recent_emoji":
                                                  .success(#"{"recent_emoji":[{"emoji":"👋","total":2},{"emoji":"mxc://example.org/party","total":4,"shortcode":"party"}]}"#)
                                              case "io.element.recent_emoji":
                                                  .success(#"{"recent_emoji":[["👋",3],["👍",3]]}"#)
                                              default:
                                                  .success(nil)
                                              }
                                          },
                                          accountDataWriter: { _, _ in .success(()) })
        
        _ = await store.entries()
        
        #expect(store.rankedEntries == [
            .init(emoji: "mxc://example.org/party", total: 4, shortcode: "party"),
            .init(emoji: "👋", total: 3, shortcode: nil),
            .init(emoji: "👍", total: 3, shortcode: nil),
            .init(emoji: "❤️", total: 0, shortcode: nil)
        ])
    }
    
    @Test
    func recordsCustomUsageInStableAccountData() async throws {
        var writtenEventType: String?
        var writtenContent: String?
        let store = NitroRecentEmojiStore(baseProvider: RecentStoreTestEmojiProvider(),
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
                                          })
        
        await store.recordUsage(emoji: "mxc://example.org/party", shortcode: "party")
        
        let content = try #require(writtenContent?.data(using: .utf8))
        let accountData = try JSONDecoder().decode(RecentEmojiAccountData.self, from: content)
        #expect(writtenEventType == "m.recent_emoji")
        #expect(accountData.recentEmoji == [
            .init(emoji: "mxc://example.org/party", total: 1, shortcode: "party"),
            .init(emoji: "👋", total: 2, shortcode: nil)
        ])
    }
    
    @Test
    func failedAccountDataReadDoesNotOverwriteServerHistory() async {
        var writeCount = 0
        let store = NitroRecentEmojiStore(baseProvider: RecentStoreTestEmojiProvider(),
                                          accountDataProvider: { eventType in
                                              eventType == "m.recent_emoji" ? .failure(.invalidResponse) : .success(nil)
                                          },
                                          accountDataWriter: { _, _ in
                                              writeCount += 1
                                              return .success(())
                                          })
        
        await store.recordUsage(emoji: "👋", shortcode: nil)
        
        #expect(writeCount == 0)
        #expect(store.rankedEntries.first == .init(emoji: "👋", total: 1, shortcode: nil))
    }
    
    @Test
    func pendingUsageSurvivesAccountDataReadRecovery() async throws {
        var stableReadCount = 0
        var writtenContent: String?
        let store = NitroRecentEmojiStore(baseProvider: RecentStoreTestEmojiProvider(),
                                          accountDataProvider: { eventType in
                                              guard eventType == "m.recent_emoji" else { return .success(nil) }
                                              stableReadCount += 1
                                              return stableReadCount == 1
                                                  ? .failure(.invalidResponse)
                                                  : .success(#"{"recent_emoji":[{"emoji":"👋","total":10}]}"#)
                                          },
                                          accountDataWriter: { _, content in
                                              writtenContent = content
                                              return .success(())
                                          })
        
        await store.recordUsage(emoji: "👋", shortcode: nil)
        await store.recordUsage(emoji: "👋", shortcode: nil)
        
        let content = try #require(writtenContent?.data(using: .utf8))
        let decoded = try JSONDecoder().decode(RecentEmojiAccountData.self, from: content)
        #expect(decoded.recentEmoji.first == .init(emoji: "👋", total: 12, shortcode: nil))
    }
    
    @Test
    func entriesFlushesPendingUsageAfterAccountDataReadRecovery() async throws {
        var stableReadCount = 0
        var writtenContent: String?
        let store = NitroRecentEmojiStore(baseProvider: RecentStoreTestEmojiProvider(),
                                          accountDataProvider: { eventType in
                                              guard eventType == "m.recent_emoji" else { return .success(nil) }
                                              stableReadCount += 1
                                              return stableReadCount == 1
                                                  ? .failure(.invalidResponse)
                                                  : .success(#"{"recent_emoji":[{"emoji":"👋","total":10}]}"#)
                                          },
                                          accountDataWriter: { _, content in
                                              writtenContent = content
                                              return .success(())
                                          })
        
        await store.recordUsage(emoji: "👋", shortcode: nil)
        let entries = await store.entries()
        
        let content = try #require(writtenContent?.data(using: .utf8))
        let decoded = try JSONDecoder().decode(RecentEmojiAccountData.self, from: content)
        #expect(entries.first == .init(emoji: "👋", total: 11, shortcode: nil))
        #expect(decoded.recentEmoji.first == .init(emoji: "👋", total: 11, shortcode: nil))
    }
    
    @Test
    func failedWritePreservesPendingUsageUntilRetrySucceeds() async throws {
        var writeCount = 0
        var writtenContent: String?
        let store = NitroRecentEmojiStore(baseProvider: RecentStoreTestEmojiProvider(),
                                          accountDataProvider: { _ in .success(nil) },
                                          accountDataWriter: { _, content in
                                              writeCount += 1
                                              writtenContent = content
                                              return writeCount == 1 ? .failure(.invalidResponse) : .success(())
                                          })
        
        await store.recordUsage(emoji: "👋", shortcode: nil)
        let entries = await store.entries()
        
        let content = try #require(writtenContent?.data(using: .utf8))
        let decoded = try JSONDecoder().decode(RecentEmojiAccountData.self, from: content)
        #expect(entries.first == .init(emoji: "👋", total: 1, shortcode: nil))
        #expect(decoded.recentEmoji.first == .init(emoji: "👋", total: 1, shortcode: nil))
        #expect(writeCount == 2)
    }
    
    @Test
    func serializesOverlappingUsageWrites() async throws {
        var accountData = #"{"recent_emoji":[]}"#
        let writeGate = RecentEmojiWriteGate()
        var writeCount = 0
        let store = NitroRecentEmojiStore(baseProvider: RecentStoreTestEmojiProvider(),
                                          accountDataProvider: { eventType in
                                              .success(eventType == "m.recent_emoji" ? accountData : nil)
                                          },
                                          accountDataWriter: { _, content in
                                              writeCount += 1
                                              if writeCount == 1 {
                                                  await writeGate.blockFirstWrite()
                                              }
                                              accountData = content
                                              return .success(())
                                          })
        let firstUsage = Task { await store.recordUsage(emoji: "👋", shortcode: nil) }
        await writeGate.waitUntilFirstWriteStarted()
        let secondUsage = Task { await store.recordUsage(emoji: "👋", shortcode: nil) }
        
        await writeGate.releaseFirstWrite()
        await firstUsage.value
        await secondUsage.value
        
        let content = try #require(accountData.data(using: .utf8))
        let decoded = try JSONDecoder().decode(RecentEmojiAccountData.self, from: content)
        #expect(decoded.recentEmoji.first == .init(emoji: "👋", total: 2, shortcode: nil))
        #expect(writeCount == 2)
    }
    
    @Test
    func entriesIncludesUsageQueuedBehindAnEarlierWrite() async {
        var accountData = #"{"recent_emoji":[]}"#
        let writeGate = RecentEmojiWriteGate()
        var writeCount = 0
        let store = NitroRecentEmojiStore(baseProvider: RecentStoreTestEmojiProvider(),
                                          accountDataProvider: { eventType in
                                              .success(eventType == "m.recent_emoji" ? accountData : nil)
                                          },
                                          accountDataWriter: { _, content in
                                              writeCount += 1
                                              if writeCount == 1 {
                                                  await writeGate.blockFirstWrite()
                                              }
                                              accountData = content
                                              return .success(())
                                          })
        let firstUsage = Task { await store.recordUsage(emoji: "👋", shortcode: nil) }
        await writeGate.waitUntilFirstWriteStarted()
        let secondUsageAndEntries = Task {
            await store.recordUsage(emoji: "👋", shortcode: nil)
            return await store.entries()
        }
        
        await writeGate.releaseFirstWrite()
        await firstUsage.value
        
        #expect(await secondUsageAndEntries.value.first == .init(emoji: "👋", total: 2, shortcode: nil))
    }
    
    @Test
    func limitsPersistedHistoryToOneHundredEntries() async throws {
        let entries = (0..<100)
            .map { #"{"emoji":"mxc://example.org/\#($0)","total":0}"# }
            .joined(separator: ",")
        var accountData = #"{"recent_emoji":[\#(entries)]}"#
        let store = NitroRecentEmojiStore(baseProvider: RecentStoreTestEmojiProvider(),
                                          accountDataProvider: { eventType in
                                              .success(eventType == "m.recent_emoji" ? accountData : nil)
                                          },
                                          accountDataWriter: { _, content in
                                              accountData = content
                                              return .success(())
                                          })
        
        await store.recordUsage(emoji: "mxc://example.org/new", shortcode: "new")
        
        let content = try #require(accountData.data(using: .utf8))
        let decoded = try JSONDecoder().decode(RecentEmojiAccountData.self, from: content)
        #expect(decoded.recentEmoji.count == 100)
        #expect(decoded.recentEmoji.first == .init(emoji: "mxc://example.org/new", total: 1, shortcode: "new"))
        #expect(decoded.recentEmoji.last?.emoji == "mxc://example.org/98")
    }
}

private actor RecentEmojiWriteGate {
    private var firstWriteStarted = false
    private var startWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    
    func blockFirstWrite() async {
        firstWriteStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }
    
    func waitUntilFirstWriteStarted() async {
        guard !firstWriteStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    
    func releaseFirstWrite() {
        releaseContinuation?.resume()
        releaseContinuation = nil
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
private final class RecentStoreTestEmojiProvider: EmojiProviderProtocol {
    private let frequentlyUsedEmojis: [String]
    
    init(frequentlyUsedEmojis: [String] = []) {
        self.frequentlyUsedEmojis = frequentlyUsedEmojis
    }
    
    func categories(searchString: String?) async -> [EmojiCategory] {
        []
    }
    
    func frequentlyUsedSystemEmojis() -> [String] {
        frequentlyUsedEmojis
    }
    
    func markEmojiAsFrequentlyUsed(_ emoji: String) { }
}
