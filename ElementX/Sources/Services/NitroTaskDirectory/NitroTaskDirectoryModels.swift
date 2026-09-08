//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Synchronization

final nonisolated class NitroTaskDirectoryRunToken: Sendable {
    private let isActiveState = Mutex(true)
    
    func invalidate() {
        isActiveState.withLock { $0 = false }
    }
    
    func performIfActive(_ operation: () -> Void) -> Bool {
        isActiveState.withLock { isActive in
            guard isActive else { return false }
            operation()
            return true
        }
    }
    
    func performIfActiveReturningSuccess(_ operation: () -> Bool) -> Bool {
        isActiveState.withLock { isActive in
            guard isActive else { return false }
            return operation()
        }
    }
}

nonisolated struct NitroTaskDirectoryKey: Codable, Equatable, Hashable, Sendable {
    let roomID: String
    let taskEventID: String
    
    var isValid: Bool {
        Self.isMatrixID(roomID, sigil: "!") && Self.isMatrixID(taskEventID, sigil: "$")
    }
    
    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case taskEventID = "task_event_id"
    }
    
    private static func isMatrixID(_ value: String, sigil: Character) -> Bool {
        value.first == sigil && value.count <= 1024 && !value.contains(where: \.isWhitespace)
    }
}

nonisolated struct NitroTaskDirectoryHint: Decodable, Equatable, Sendable {
    let key: NitroTaskDirectoryKey
    let contentEventID: String
    let contentOriginTimestamp: UInt64
    let stateEventID: String?
    let stateOriginTimestamp: UInt64?
    let revision: UInt64
    let isFresh: Bool
    
    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case taskEventID = "task_event_id"
        case contentEventID = "content_event_id"
        case contentOriginTimestamp = "content_origin_ts"
        case stateEventID = "state_event_id"
        case stateOriginTimestamp = "state_origin_ts"
        case revision
        case isFresh = "fresh"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let roomID = try container.decode(String.self, forKey: .roomID)
        let taskEventID = try container.decode(String.self, forKey: .taskEventID)
        let contentEventID = try container.decode(String.self, forKey: .contentEventID)
        let stateEventID = try container.decodeIfPresent(String.self, forKey: .stateEventID)
        let stateOriginTimestamp = try container.decodeIfPresent(UInt64.self, forKey: .stateOriginTimestamp)
        guard Self.isMatrixID(roomID, sigil: "!"),
              Self.isMatrixID(taskEventID, sigil: "$"),
              Self.isMatrixID(contentEventID, sigil: "$"),
              stateEventID.map({ Self.isMatrixID($0, sigil: "$") }) ?? true,
              (stateEventID == nil) == (stateOriginTimestamp == nil) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid task directory hint"))
        }
        key = .init(roomID: roomID, taskEventID: taskEventID)
        self.contentEventID = contentEventID
        contentOriginTimestamp = try container.decode(UInt64.self, forKey: .contentOriginTimestamp)
        self.stateEventID = stateEventID
        self.stateOriginTimestamp = stateOriginTimestamp
        revision = try container.decode(UInt64.self, forKey: .revision)
        isFresh = try container.decode(Bool.self, forKey: .isFresh)
        guard revision > 0,
              contentOriginTimestamp <= 10_000_000_000_000,
              stateOriginTimestamp.map({ $0 <= 10_000_000_000_000 }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid task directory revision"))
        }
    }
    
    private static func isMatrixID(_ value: String, sigil: Character) -> Bool {
        value.first == sigil && value.count <= 1024 && !value.contains(where: \.isWhitespace)
    }
}

nonisolated enum NitroTaskDirectoryStatePointer: Codable, Equatable, Sendable {
    case none
    case event(id: String, originTimestamp: UInt64)
}

nonisolated struct NitroTaskDirectoryUpdate: Codable, Equatable, Sendable {
    let key: NitroTaskDirectoryKey
    var baseRevision: UInt64?
    var contentEventID: String?
    var contentOriginTimestamp: UInt64?
    var statePointer: NitroTaskDirectoryStatePointer?
    var isAuthoritative = false
    var invalidates = false
    
    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case taskEventID = "task_event_id"
        case baseRevision = "base_revision"
        case contentEventID = "content_event_id"
        case contentOriginTimestamp = "content_origin_ts"
        case stateEventID = "state_event_id"
        case stateOriginTimestamp = "state_origin_ts"
        case isAuthoritative = "authoritative"
        case invalidates = "invalidate"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key.roomID, forKey: .roomID)
        try container.encode(key.taskEventID, forKey: .taskEventID)
        try container.encodeIfPresent(baseRevision, forKey: .baseRevision)
        try container.encodeIfPresent(contentEventID, forKey: .contentEventID)
        try container.encodeIfPresent(contentOriginTimestamp, forKey: .contentOriginTimestamp)
        switch statePointer {
        case .some(.none):
            try container.encodeNil(forKey: .stateEventID)
            try container.encodeNil(forKey: .stateOriginTimestamp)
        case .some(.event(let id, let originTimestamp)):
            try container.encode(id, forKey: .stateEventID)
            try container.encode(originTimestamp, forKey: .stateOriginTimestamp)
        case Optional.none:
            break
        }
        if isAuthoritative {
            try container.encode(true, forKey: .isAuthoritative)
        }
        if invalidates {
            try container.encode(true, forKey: .invalidates)
        }
    }
    
    init(key: NitroTaskDirectoryKey,
         baseRevision: UInt64? = nil,
         contentEventID: String? = nil,
         contentOriginTimestamp: UInt64? = nil,
         statePointer: NitroTaskDirectoryStatePointer? = nil,
         isAuthoritative: Bool = false,
         invalidates: Bool = false) {
        self.key = key
        self.baseRevision = baseRevision
        self.contentEventID = contentEventID
        self.contentOriginTimestamp = contentOriginTimestamp
        self.statePointer = statePointer
        self.isAuthoritative = isAuthoritative
        self.invalidates = invalidates
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try .init(roomID: container.decode(String.self, forKey: .roomID),
                        taskEventID: container.decode(String.self, forKey: .taskEventID))
        baseRevision = try container.decodeIfPresent(UInt64.self, forKey: .baseRevision)
        contentEventID = try container.decodeIfPresent(String.self, forKey: .contentEventID)
        contentOriginTimestamp = try container.decodeIfPresent(UInt64.self, forKey: .contentOriginTimestamp)
        if container.contains(.stateEventID) || container.contains(.stateOriginTimestamp) {
            if let stateEventID = try container.decodeIfPresent(String.self, forKey: .stateEventID) {
                statePointer = try .event(id: stateEventID,
                                          originTimestamp: container.decode(UInt64.self, forKey: .stateOriginTimestamp))
            } else {
                statePointer = NitroTaskDirectoryStatePointer.none
            }
        } else {
            statePointer = nil
        }
        isAuthoritative = try container.decodeIfPresent(Bool.self, forKey: .isAuthoritative) ?? false
        invalidates = try container.decodeIfPresent(Bool.self, forKey: .invalidates) ?? false
    }
    
    var isValid: Bool {
        guard key.isValid,
              (contentEventID == nil) == (contentOriginTimestamp == nil),
              contentOriginTimestamp.map({ $0 <= 10_000_000_000_000 }) ?? true,
              contentEventID.map({ $0.first == "$" && $0.count <= 1024 && !$0.contains(where: \.isWhitespace) }) ?? true else {
            return false
        }
        switch statePointer {
        case .some(.event(let id, let originTimestamp)):
            guard id.first == "$", id.count <= 1024, !id.contains(where: \.isWhitespace),
                  originTimestamp <= 10_000_000_000_000 else {
                return false
            }
        case .some(.none), Optional.none:
            break
        }
        return contentEventID != nil || statePointer != nil || invalidates
    }
}

nonisolated struct NitroTaskDirectoryUpdateResult: Decodable, Equatable, Sendable {
    let key: NitroTaskDirectoryKey
    let revision: UInt64
    let isApplied: Bool
    let hasConflict: Bool
    
    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case taskEventID = "task_event_id"
        case revision
        case isApplied = "applied"
        case hasConflict = "conflict"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try .init(roomID: container.decode(String.self, forKey: .roomID),
                        taskEventID: container.decode(String.self, forKey: .taskEventID))
        revision = try container.decode(UInt64.self, forKey: .revision)
        isApplied = try container.decode(Bool.self, forKey: .isApplied)
        hasConflict = try container.decode(Bool.self, forKey: .hasConflict)
        guard key.isValid, isApplied != hasConflict else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid task directory update result"))
        }
    }
}

nonisolated struct NitroTaskDirectoryAuthentication: Sendable {
    let homeserverURL: String
    let openIDToken: NitroOpenIDToken
}

nonisolated enum NitroTaskDirectoryError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
}
