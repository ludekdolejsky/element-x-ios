//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum BlockquoteAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "MXBlockquoteAttribute"
}

enum UserIDAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "MXUserIDAttribute"
}

/// This attribute is used to help the composer convert a mention into to a markdown link before sending
/// the message. It doesn't interact mention pills, as these fetch display names live from the room.
enum UserDisplayNameAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "MXUserDisplayNameAttribute"
}

enum RoomDisplayNameAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "MXRoomDisplayNameAttribute"
}

enum RoomIDAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "MXRoomIDAttribute"
}

enum RoomAliasAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "MXRoomAliasAttribute"
}

enum EventOnRoomIDAttribute: AttributedStringKey {
    struct Value: Hashable {
        let roomID: String
        // periphery:ignore - used via the synthesized Hashable conformance
        let eventID: String
    }
    
    static let name = "MXEventOnRoomIDAttribute"
}

enum EventOnRoomAliasAttribute: AttributedStringKey {
    struct Value: Hashable {
        let alias: String
        // periphery:ignore - used via the synthesized Hashable conformance
        let eventID: String
    }
    
    static let name = "MXEventOnRoomAliasAttribute"
}

enum AllUsersMentionAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "MXAllUsersMentionAttribute"
}

enum CodeBlockAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "MXCodeBlockAttribute"
}

enum InlineCodeAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "MXInlineCodeAttribute"
}

enum TableAttribute: AttributedStringKey {
    enum CellAlignment: Hashable {
        case left
        case center
        case right
    }
    
    struct Row: Hashable {
        let cells: [Cell]
    }
    
    struct Cell: Hashable {
        let content: AttributedString
        let alignment: CellAlignment
        let isHeader: Bool
    }
    
    struct Value: Hashable {
        let id = UUID()
        let caption: AttributedString?
        let headerRows: [Row]
        let bodyRows: [Row]
    }
    
    static let name = "MXTableAttribute"
}

extension TableAttribute.Value {
    nonisolated var accessibilityLabel: String {
        var parts = (headerRows + bodyRows).map(\.accessibilityLabel)
        if let caption {
            parts.insert(caption.string, at: 0)
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private extension TableAttribute.Row {
    nonisolated var accessibilityLabel: String {
        cells.map { $0.content.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: ", ")
    }
}

nonisolated extension AttributeScopes {
    struct ElementXAttributes: AttributeScope {
        let blockquote: BlockquoteAttribute
        
        let userID: UserIDAttribute
        // periphery:ignore - required to make NSAttributedString to AttributedString conversion even if not used directly
        let userDisplayName: UserDisplayNameAttribute
        // periphery:ignore - required to make NSAttributedString to AttributedString conversion even if not used directly
        let roomDisplayName: RoomDisplayNameAttribute
        let roomID: RoomIDAttribute
        let roomAlias: RoomAliasAttribute
        let eventOnRoomID: EventOnRoomIDAttribute
        let eventOnRoomAlias: EventOnRoomAliasAttribute
        
        // periphery:ignore - required to make NSAttributedString to AttributedString conversion even if not used directly
        
        let allUsersMention: AllUsersMentionAttribute
        
        let codeBlock: CodeBlockAttribute
        // periphery:ignore - required to make NSAttributedString to AttributedString conversion even if not used directly
        let inlineCode: InlineCodeAttribute
        let table: TableAttribute
        
        // periphery:ignore - required to make NSAttributedString to AttributedString conversion even if not used directly
        
        let swiftUI: SwiftUIAttributes
        // periphery:ignore - required to make NSAttributedString to AttributedString conversion even if not used directly
        let uiKit: UIKitAttributes
    }
    
    var elementX: ElementXAttributes.Type {
        ElementXAttributes.self
    }
}

// periphery: ignore - required to make NSAttributedString to AttributedString conversion even if not used directly
nonisolated extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.ElementXAttributes, T>) -> T {
        self[T.self]
    }
}
