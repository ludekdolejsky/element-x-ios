//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct NitroTaskCard: View {
    @Environment(\.colorScheme) private var colorScheme
    
    let task: NitroTask
    let isBusy: Bool
    let useCardBackground: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.metadata.title)
                        .font(.compound.bodyMDSemibold)
                        .foregroundStyle(.compound.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                
                if let sourceText = task.sourceText, sourceText != task.metadata.title {
                    Text(sourceText)
                        .font(.compound.bodySM)
                        .foregroundStyle(.compound.textSecondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                
                HStack(spacing: 6) {
                    Text(task.roomName)
                        .lineLimit(1)
                    Text("•")
                    Text(assigneeTitle)
                        .lineLimit(1)
                    if !task.stateIsAvailable {
                        Spacer(minLength: 4)
                        CompoundIcon(\.warning, size: .xSmall, relativeTo: .compound.bodyXS)
                            .accessibilityLabel(UntranslatedL10n.screenNitroTaskStateUnavailableIos)
                    }
                }
                .font(.compound.bodyXS)
                .foregroundStyle(.compound.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(useCardBackground ? 12 : 4)
            .background {
                if useCardBackground || task.state.assignee != nil {
                    cardBackground
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
    
    private var assigneeTitle: String {
        task.assigneeDisplayName ?? task.state.assignee ?? UntranslatedL10n.screenNitroTaskUnassignedIos
    }
    
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: useCardBackground ? 12 : 8)
        let assigneeColor = task.state.assignee.map(NitroTaskAssigneeColor.color)
        
        return ZStack {
            shape.fill(assigneeColor == nil && useCardBackground ? Color.compound.bgSubtleSecondary : .compound.bgCanvasDefault)
            if let assigneeColor {
                shape.fill(assigneeColor.opacity(colorScheme == .dark ? 0.15 : 0.10))
                if useCardBackground {
                    shape.stroke(Color.compound.borderInteractiveSecondary, lineWidth: 1)
                    shape.stroke(assigneeColor.opacity(colorScheme == .dark ? 0.38 : 0.28), lineWidth: 1)
                }
            }
        }
    }
}

enum NitroTaskAssigneeColor {
    static let count = colors.count
    
    static func index(for userID: String) -> Int {
        var hash: UInt32 = 0x811C_9DC5
        for codeUnit in userID.utf16 {
            hash ^= UInt32(codeUnit)
            hash &*= 0x0100_0193
        }
        return Int(hash % UInt32(count))
    }
    
    static func color(for userID: String) -> Color {
        colors[index(for: userID)]
    }
    
    private static let colors = [
        Color(red: 225 / 255, green: 29 / 255, blue: 72 / 255),
        Color(red: 234 / 255, green: 88 / 255, blue: 12 / 255),
        Color(red: 202 / 255, green: 138 / 255, blue: 4 / 255),
        Color(red: 101 / 255, green: 163 / 255, blue: 13 / 255),
        Color(red: 5 / 255, green: 150 / 255, blue: 105 / 255),
        Color(red: 13 / 255, green: 148 / 255, blue: 136 / 255),
        Color(red: 8 / 255, green: 145 / 255, blue: 178 / 255),
        Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255),
        Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255),
        Color(red: 124 / 255, green: 58 / 255, blue: 237 / 255),
        Color(red: 192 / 255, green: 38 / 255, blue: 211 / 255),
        Color(red: 219 / 255, green: 39 / 255, blue: 119 / 255)
    ]
}
