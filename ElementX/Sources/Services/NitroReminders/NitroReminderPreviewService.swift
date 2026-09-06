//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatrixRustSDK

nonisolated struct NitroReminderMessagePreview: Equatable, Sendable {
    let text: String
    let sender: String?
    let isEdited: Bool
    let isAvailable: Bool
}

nonisolated struct NitroReminderPreviewUpdate: Equatable, Sendable {
    let reminderID: String
    let preview: NitroReminderMessagePreview
}

protocol NitroReminderPreviewServiceProtocol {
    func loadPreviews(for reminders: [NitroReminder],
                      forceRefresh: Bool,
                      update: @escaping @MainActor @Sendable (NitroReminderPreviewUpdate) -> Void) async
}

final class NitroReminderPreviewService: NitroReminderPreviewServiceProtocol {
    private nonisolated struct Target: Hashable, Sendable {
        let roomID: String
        let eventID: String
    }
    
    private nonisolated struct TargetWork: Sendable {
        let target: Target
        let reminderIDs: [String]
    }
    
    private nonisolated struct CacheEntry: Sendable {
        let preview: NitroReminderMessagePreview
        let expirationDate: Date
    }
    
    private static let maximumConcurrentLoads = 4
    private static let maximumCacheEntries = 200
    private static let loadTimeout: Duration = .seconds(10)
    private static let availableCacheDuration: TimeInterval = 5 * 60
    private static let unavailableCacheDuration: TimeInterval = 60
    
    private let clientProxy: ClientProxyProtocol
    private let now: () -> Date
    private var cache = [Target: CacheEntry]()
    private var cacheOrder = [Target]()
    
    init(clientProxy: ClientProxyProtocol, now: @escaping () -> Date = Date.init) {
        self.clientProxy = clientProxy
        self.now = now
    }
    
    func loadPreviews(for reminders: [NitroReminder],
                      forceRefresh: Bool,
                      update: @escaping @MainActor @Sendable (NitroReminderPreviewUpdate) -> Void) async {
        await producePreviewUpdates(for: reminders, forceRefresh: forceRefresh, update: update)
    }
    
    private func store(_ preview: NitroReminderMessagePreview, for target: Target) {
        cacheOrder.removeAll { $0 == target }
        cacheOrder.append(target)
        let cacheDuration = preview.isAvailable ? Self.availableCacheDuration : Self.unavailableCacheDuration
        cache[target] = .init(preview: preview,
                              expirationDate: now().addingTimeInterval(cacheDuration))
        
        while cacheOrder.count > Self.maximumCacheEntries {
            cache[cacheOrder.removeFirst()] = nil
        }
    }
    
    private func cachedPreview(for target: Target) -> NitroReminderMessagePreview? {
        guard let entry = cache[target] else { return nil }
        if entry.expirationDate <= now() {
            cache[target] = nil
            cacheOrder.removeAll { $0 == target }
            return nil
        }
        return entry.preview
    }
    
    private func producePreviewUpdates(for reminders: [NitroReminder],
                                       forceRefresh: Bool,
                                       update: @escaping @MainActor @Sendable (NitroReminderPreviewUpdate) -> Void) async {
        var reminderIDsByTarget = [Target: [String]]()
        var targets = [Target]()
        for reminder in reminders {
            let target = Target(roomID: reminder.roomID, eventID: reminder.eventID)
            if reminderIDsByTarget[target] == nil {
                targets.append(target)
            }
            reminderIDsByTarget[target, default: []].append(reminder.id)
        }
        
        if forceRefresh {
            for target in targets {
                cache[target] = nil
                cacheOrder.removeAll { $0 == target }
            }
        }
        
        let work = targets.map { target in
            TargetWork(target: target, reminderIDs: reminderIDsByTarget[target] ?? [])
        }
        var uncachedWork = [TargetWork]()
        for item in work {
            if let preview = cachedPreview(for: item.target) {
                yield(preview, for: item.reminderIDs, update: update)
            } else {
                uncachedWork.append(item)
            }
        }
        
        let partitions = (0..<Self.maximumConcurrentLoads).map { offset in
            stride(from: offset, to: uncachedWork.count, by: Self.maximumConcurrentLoads).map { uncachedWork[$0] }
        }
        async let firstPartition: Void = loadPreviews(for: partitions[0], update: update)
        async let secondPartition: Void = loadPreviews(for: partitions[1], update: update)
        async let thirdPartition: Void = loadPreviews(for: partitions[2], update: update)
        async let fourthPartition: Void = loadPreviews(for: partitions[3], update: update)
        _ = await (firstPartition, secondPartition, thirdPartition, fourthPartition)
    }
    
    private func loadPreviews(for work: [TargetWork],
                              update: @escaping @MainActor @Sendable (NitroReminderPreviewUpdate) -> Void) async {
        for item in work {
            guard !Task.isCancelled else { return }
            let preview = await loadPreview(for: item.target)
            guard !Task.isCancelled else { return }
            store(preview, for: item.target)
            yield(preview, for: item.reminderIDs, update: update)
        }
    }
    
    private func yield(_ preview: NitroReminderMessagePreview,
                       for reminderIDs: [String],
                       update: @MainActor @Sendable (NitroReminderPreviewUpdate) -> Void) {
        for reminderID in reminderIDs {
            update(.init(reminderID: reminderID, preview: preview))
        }
    }
    
    private func loadPreview(for target: Target) async -> NitroReminderMessagePreview {
        guard case let .joined(roomProxy) = await clientProxy.roomForIdentifier(target.roomID),
              !Task.isCancelled,
              case let .success(timeline) = await roomProxy.timelineFocusedOnEvent(eventID: target.eventID, numberOfEvents: 0),
              !Task.isCancelled else {
            return Self.unavailablePreview
        }
        
        await timeline.subscribeForUpdates(fetchMembers: false)
        guard !Task.isCancelled else { return Self.unavailablePreview }
        let provider = timeline.timelineItemProvider
        if let preview = Self.preview(for: target.eventID, in: provider.itemProxies) {
            return preview
        }
        
        let (stream, continuation) = AsyncStream<[TimelineItemProxy]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancellable = provider.updatePublisher.sink { items, _ in
            continuation.yield(items)
        }
        defer {
            cancellable.cancel()
            continuation.finish()
        }
        
        return await withTaskGroup(of: NitroReminderMessagePreview.self) { group in
            group.addTask {
                for await items in stream {
                    if let preview = Self.preview(for: target.eventID, in: items) {
                        return preview
                    }
                    guard !Task.isCancelled else { return Self.unavailablePreview }
                }
                return Self.unavailablePreview
            }
            group.addTask {
                try? await Task.sleep(for: Self.loadTimeout)
                return Self.unavailablePreview
            }
            let result = await group.next() ?? Self.unavailablePreview
            group.cancelAll()
            return result
        }
    }
    
    nonisolated static func preview(for eventID: String,
                                    in items: [TimelineItemProxy]) -> NitroReminderMessagePreview? {
        guard let event = items.compactMap({ item -> EventTimelineItemProxy? in
            guard case let .event(event) = item, event.id.eventID == eventID else { return nil }
            return event
        }).first else {
            return nil
        }
        
        let sender = event.sender.disambiguatedDisplayName ?? event.sender.displayName ?? event.sender.id
        guard case let .msgLike(content) = event.content else {
            return Self.unavailablePreview
        }
        
        let text: String
        let isEdited: Bool
        switch content.kind {
        case .message(let message):
            text = message.body
            isEdited = message.isEdited
        case .sticker(let body, _, _):
            text = body.isEmpty ? L10n.commonSticker : body
            isEdited = false
        case .poll(let question, _, _, _, _, _, let hasBeenEdited):
            text = L10n.commonPollSummary(question)
            isEdited = hasBeenEdited
        case .liveLocation:
            text = L10n.commonLiveLocation
            isEdited = false
        case .redacted, .unableToDecrypt, .other:
            return Self.unavailablePreview
        }
        
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return Self.unavailablePreview }
        return .init(text: trimmedText, sender: sender, isEdited: isEdited, isAvailable: true)
    }
    
    private nonisolated static var unavailablePreview: NitroReminderMessagePreview {
        .init(text: UntranslatedL10n.screenNitroRemindersMessageUnavailableIos,
              sender: nil,
              isEdited: false,
              isAvailable: false)
    }
}
