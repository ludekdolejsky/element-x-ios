//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

struct TimelineItemMenuActionProvider {
    let timelineItem: RoomTimelineItemProtocol
    let canCurrentUserSendMessage: Bool
    let canCurrentUserRedactSelf: Bool
    let canCurrentUserRedactOthers: Bool
    let canCurrentUserPin: Bool
    let pinnedEventIDs: Set<String>
    let isViewSourceEnabled: Bool
    let areThreadsEnabled: Bool
    let timelineKind: TimelineKind
    let emojiProvider: EmojiProviderProtocol
    
    // swiftlint:disable:next cyclomatic_complexity
    func makeActions() -> TimelineItemMenuActions? {
        guard let item = timelineItem as? EventBasedTimelineItemProtocol else {
            // Don't show a context menu for non-event based items.
            return nil
        }
        
        if timelineItem is StateRoomTimelineItem {
            // Don't show a context menu for state events.
            return nil
        }
        
        if timelineItem is EncryptedRoomTimelineItem {
            return makeEncryptedItemActions()
        }
        
        var actions: [TimelineItemMenuAction] = []
        var secondaryActions: [TimelineItemMenuAction] = []
        
        if timelineKind == .pinned || timelineKind == .media(.mediaFilesScreen) || timelineKind == .media(.pinnedEventsScreen) {
            actions.append(.viewInRoomTimeline)
        }
        
        if canRedactItem(item), let poll = item.pollIfAvailable, !poll.hasEnded, let eventID = item.id.eventID {
            actions.append(.endPoll(pollStartID: eventID))
        }
        
        if item.canBeRepliedTo, canCurrentUserSendMessage {
            if let messageItem = item as? EventBasedMessageTimelineItemProtocol {
                // If threads are enabled we will have the dedicated `replyInThread` action
                // so there is no need to make the normal reply use the thread.
                actions.append(.reply(isThread: areThreadsEnabled ? false : messageItem.properties.isThreaded))
            } else {
                actions.append(.reply(isThread: false))
            }
            
            if areThreadsEnabled, !timelineKind.isThread {
                actions.append(.replyInThread)
            }
        }
        
        if item.isForwardable {
            actions.append(.forward(itemID: item.id))
        }
        
        actions.append(contentsOf: audioTranscriptionActions(for: item))
        
        if item.isEditable, canCurrentUserSendMessage {
            if item.supportsMediaCaption {
                if item.hasMediaCaption {
                    actions.append(.editCaption)
                } else {
                    actions.append(.addCaption)
                }
            } else if item is PollRoomTimelineItem {
                actions.append(.editPoll)
            } else if !(item is VoiceMessageRoomTimelineItem) {
                actions.append(.edit)
            }
        }
        
        if item.isRemoteMessage {
            actions.append(contentsOf: nitroActions())
            actions.append(.copyPermalink)
        }
        
        if canCurrentUserPin, let eventID = item.id.eventID {
            actions.append(pinnedEventIDs.contains(eventID) ? .unpin : .pin)
        }
        
        if item.isCopyable {
            actions.append(contentsOf: copyActions())
        } else if item.hasMediaCaption {
            actions.append(.copyCaption)
        }
        
        if item.isEditable, item.hasMediaCaption {
            actions.append(.removeCaption)
        }
        
        if isViewSourceEnabled {
            actions.append(.viewSource)
        }
        
        if !item.isOutgoing {
            secondaryActions.append(.report)
        }
        
        if canRedactItem(item) {
            let isMedia = if case .media = timelineKind {
                true
            } else {
                false
            }
            secondaryActions.append(.redact(isMedia: isMedia))
        }
        
        switch timelineKind {
        case .pinned:
            actions = actions.filter(\.canAppearInPinnedEventsTimeline)
            secondaryActions = secondaryActions.filter(\.canAppearInPinnedEventsTimeline)
        case .media:
            actions.append(.downloadMedia)
            actions = actions.filter(\.canAppearInMediaDetails)
            secondaryActions = secondaryActions.filter(\.canAppearInMediaDetails)
        case .live, .detached, .thread:
            break // viewInRoomTimeline is the only non-room item and was added conditionally.
        }
        
        if item.hasFailedToSend {
            actions = actions.filter(\.canAppearInFailedEcho)
            secondaryActions = secondaryActions.filter(\.canAppearInFailedEcho)
        }
        
        if item.isRedacted {
            actions = actions.filter(\.canAppearInRedacted)
            secondaryActions = secondaryActions.filter(\.canAppearInRedacted)
        }
        
        let isReactable = timelineKind == .live || timelineKind == .detached || timelineKind.isThread ? item.isReactable : false
        
        return .init(isReactable: isReactable, actions: actions, secondaryActions: secondaryActions, emojiProvider: emojiProvider)
    }
    
    private func copyActions() -> [TimelineItemMenuAction] {
        var actions: [TimelineItemMenuAction] = [.copy]
        if !ProcessInfo.processInfo.isiOSAppOnMac {
            actions.append(.translate)
        }
        return actions
    }
    
    private func makeEncryptedItemActions() -> TimelineItemMenuActions? {
        var actions: [TimelineItemMenuAction] = [.copyPermalink]
        if NitroConfiguration.isEnabled {
            actions.insert(.remindMe, at: 0)
        }
        
        if isViewSourceEnabled {
            actions.append(.viewSource)
        }
        
        return .init(isReactable: false,
                     actions: actions,
                     secondaryActions: [],
                     emojiProvider: emojiProvider)
    }
    
    private func canRedactItem(_ item: EventBasedTimelineItemProtocol) -> Bool {
        item.isOutgoing ? canCurrentUserRedactSelf : canCurrentUserRedactOthers
    }
    
    private func nitroActions() -> [TimelineItemMenuAction] {
        guard NitroConfiguration.isEnabled else { return [] }
        return canCurrentUserSendMessage && canCurrentUserPin ? [.addTask, .remindMe] : [.remindMe]
    }
    
    private func audioTranscriptionActions(for item: EventBasedTimelineItemProtocol) -> [TimelineItemMenuAction] {
        guard NitroConfiguration.isEnabled,
              let messageItem = item as? EventBasedMessageTimelineItemProtocol,
              messageItem.audioContent?.source != nil else {
            return []
        }
        return canCurrentUserSendMessage && areThreadsEnabled ? [.transcribeAudio, .transcribeAudioToThread] : [.transcribeAudio]
    }
}

private extension EventBasedMessageTimelineItemProtocol {
    var audioContent: AudioRoomTimelineItemContent? {
        switch contentType {
        case .audio(let content), .voice(let content):
            content
        default:
            nil
        }
    }
}
