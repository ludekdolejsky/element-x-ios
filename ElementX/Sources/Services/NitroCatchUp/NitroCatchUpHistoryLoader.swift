//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

nonisolated struct NitroCatchUpEventCache<Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let sourceIdentity: ObjectIdentifier
        let value: Value
    }
    
    private var entries = [String: Entry]()
    
    mutating func value(for key: String, sourceIdentity: ObjectIdentifier, makeValue: () -> Value?) -> Value? {
        if let entry = entries[key], entry.sourceIdentity == sourceIdentity {
            return entry.value
        }
        guard let value = makeValue() else { return nil }
        entries[key] = .init(sourceIdentity: sourceIdentity, value: value)
        return value
    }
}

protocol NitroCatchUpHistoryLoaderProtocol {
    func messages(roomID: String,
                  scope: NitroCatchUpScope,
                  progress: (NitroCatchUpProgress) -> Void) async throws -> [NitroCatchUpMessage]
}

final class NitroCatchUpHistoryLoader: NitroCatchUpHistoryLoaderProtocol {
    private nonisolated enum HistoryItem: Sendable {
        case readMarker
        case timelineStart
        case event(Event)
        
        var event: Event? {
            if case let .event(event) = self {
                event
            } else {
                nil
            }
        }
    }
    
    private nonisolated struct Event: Sendable {
        let id: String
        let senderID: String
        let senderName: String
        let timestamp: UInt64
        let originalJSON: String?
        let latestJSON: String?
        let isReadByOwnUser: Bool
    }
    
    private nonisolated struct HistorySnapshot: Sendable {
        let items: [HistoryItem]
        let eventCache: NitroCatchUpEventCache<Event>
    }
    
    private nonisolated static let pageSize: UInt16 = 100
    private nonisolated static let maximumScannedEventCount = 10000
    private nonisolated static let maximumBodyLength = 50000
    
    private let client: ClientProtocol
    
    init(client: ClientProtocol) {
        self.client = client
    }
    
    func messages(roomID: String,
                  scope: NitroCatchUpScope,
                  progress: (NitroCatchUpProgress) -> Void) async throws -> [NitroCatchUpMessage] {
        guard let room = try client.getRoom(roomId: roomID), room.membership() == .joined else {
            throw NitroCatchUpServiceError.roomUnavailable
        }
        let ownUserID = try client.userId()
        let timeline = try await room.timelineWithConfiguration(configuration: .init(focus: .live(hideThreadedEvents: false),
                                                                                     filter: .all,
                                                                                     internalIdPrefix: nil,
                                                                                     dateDividerMode: .daily,
                                                                                     trackReadReceipts: .messageLikeEvents,
                                                                                     reportUtds: true))
        let timelineProxy = TimelineProxy(timeline: timeline, kind: .live)
        await timelineProxy.subscribeForUpdates()
        let timelineItemProvider = timelineProxy.timelineItemProvider
        var eventCache = NitroCatchUpEventCache<Event>()
        
        for await (items, paginationState) in timelineItemProvider.updatePublisher.values {
            try Task.checkCancellation()
            guard timelineItemProvider.hasLoadedInitialSnapshot else { continue }
            let snapshot = try await Self.historyItems(from: items, ownUserID: ownUserID, eventCache: eventCache)
            let history = snapshot.items
            eventCache = snapshot.eventCache
            let scannedEventCount = history.count { item in
                if case .event = item {
                    true
                } else {
                    false
                }
            }
            progress(.init(scannedEventCount: scannedEventCount, messageCount: 0))
            
            if let selectedEvents = Self.selectedEvents(from: history, scope: scope) {
                guard selectedEvents.count <= Self.maximumScannedEventCount else {
                    throw NitroCatchUpServiceError.rangeTooLarge
                }
                let messages = try await Self.serializedMessages(selectedEvents, roomID: roomID)
                progress(.init(scannedEventCount: scannedEventCount, messageCount: messages.count))
                return messages
            }
            if scannedEventCount >= Self.maximumScannedEventCount {
                throw NitroCatchUpServiceError.rangeTooLarge
            }
            
            switch paginationState.backward {
            case .idle:
                guard case .success = await timelineProxy.paginateBackwards(requestSize: Self.pageSize) else {
                    throw NitroCatchUpServiceError.transport
                }
            case .paginating:
                continue
            case .endReached:
                guard history.contains(where: {
                    if case .timelineStart = $0 {
                        true
                    } else {
                        false
                    }
                }) else {
                    continue
                }
                switch scope {
                case .lastRead:
                    throw NitroCatchUpServiceError.noReadMarker
                case .date:
                    let messages = try await Self.serializedMessages(history.compactMap(\.event), roomID: roomID)
                    progress(.init(scannedEventCount: scannedEventCount, messageCount: messages.count))
                    return messages
                }
            }
        }
        throw NitroCatchUpServiceError.invalidResponse
    }
    
    @concurrent
    private static func historyItems(from items: [TimelineItemProxy],
                                     ownUserID: String,
                                     eventCache initialEventCache: NitroCatchUpEventCache<Event>) async throws -> HistorySnapshot {
        var history = [HistoryItem]()
        var eventCache = initialEventCache
        for item in items {
            try Task.checkCancellation()
            switch item {
            case .virtual(let virtualItem, _):
                switch virtualItem {
                case .readMarker:
                    history.append(.readMarker)
                case .timelineStart:
                    history.append(.timelineStart)
                case .dateDivider:
                    break
                }
            case .event(let proxy):
                guard let eventID = proxy.id.eventID else { continue }
                let event = eventCache.value(for: eventID, sourceIdentity: ObjectIdentifier(proxy)) {
                    historyEvent(from: proxy, ownUserID: ownUserID)
                }
                if let event {
                    history.append(.event(event))
                }
            case .unknown:
                break
            }
        }
        return .init(items: history, eventCache: eventCache)
    }
    
    private nonisolated static func historyEvent(from proxy: EventTimelineItemProxy, ownUserID: String) -> Event? {
        let event = proxy.item
        guard case let .eventId(eventID) = event.eventOrTransactionId else { return nil }
        let displayName: String
        switch event.senderProfile {
        case .ready(let name, _, _, _, _):
            displayName = name ?? event.sender
        default:
            displayName = event.sender
        }
        let debugInfo = event.lazyProvider.debugInfo()
        return .init(id: eventID,
                     senderID: event.sender,
                     senderName: displayName,
                     timestamp: event.timestamp,
                     originalJSON: debugInfo.originalJson,
                     latestJSON: event.lazyProvider.latestJson(),
                     isReadByOwnUser: event.readReceipts[ownUserID] != nil)
    }
    
    private nonisolated static func selectedEvents(from history: [HistoryItem], scope: NitroCatchUpScope) -> [Event]? {
        switch scope {
        case .lastRead:
            if let markerIndex = history.lastIndex(where: { item in
                if case .readMarker = item {
                    true
                } else {
                    false
                }
            }) {
                return history.suffix(from: history.index(after: markerIndex)).compactMap(\.event)
            }
            guard let receiptIndex = history.lastIndex(where: { item in
                if case let .event(event) = item {
                    event.isReadByOwnUser
                } else {
                    false
                }
            }) else {
                return nil
            }
            return history.suffix(from: history.index(after: receiptIndex)).compactMap(\.event)
        case .date(let date):
            let boundary = UInt64(max(0, date.timeIntervalSince1970 * 1000))
            guard history.contains(where: { item in
                if case let .event(event) = item {
                    event.timestamp < boundary
                } else {
                    false
                }
            }) else {
                return nil
            }
            return history.compactMap(\.event).filter { $0.timestamp >= boundary }
        }
    }
    
    @concurrent
    private static func serializedMessages(_ events: [Event], roomID: String) async throws -> [NitroCatchUpMessage] {
        var buffer = NitroCatchUpMessageBuffer()
        for event in events {
            try Task.checkCancellation()
            guard let content = messageContent(event) else { continue }
            try buffer.append(.init(eventID: event.id,
                                    sender: event.senderName,
                                    senderID: event.senderID,
                                    timestamp: Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000).ISO8601Format(),
                                    body: content.body,
                                    permalink: "https://matrix.to/#/\(roomID)/\(event.id)",
                                    threadRootID: content.threadRootID))
        }
        return buffer.messages
    }
    
    private nonisolated static func messageContent(_ event: Event) -> (body: String, threadRootID: String?)? {
        guard let json = event.latestJSON ?? event.originalJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "m.room.message",
              let content = object["content"] as? [String: Any],
              let body = content["body"] as? String else {
            return nil
        }
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBody.isEmpty else { return nil }
        let originalContent = event.originalJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["content"] as? [String: Any]
        let relation = originalContent?["m.relates_to"] as? [String: Any]
        let threadRootID = relation?["rel_type"] as? String == "m.thread" ? relation?["event_id"] as? String : nil
        return (String(normalizedBody.prefix(maximumBodyLength)), threadRootID)
    }
}
