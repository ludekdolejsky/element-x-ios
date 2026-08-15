//
// Copyright 2026 Element Creations Ltd.
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

struct TimelineReactionContentView: View {
    let reaction: AggregatedReaction
    let mediaProvider: MediaProviderProtocol?
    let font: Font
    let foregroundColor: Color
    let imageSize: CGFloat
    
    var body: some View {
        if let customReactionURL = reaction.customReactionURL {
            if let mediaProvider {
                LoadableImage(url: customReactionURL,
                              size: CGSize(width: imageSize, height: imageSize),
                              allowsAnimation: true,
                              mediaProvider: mediaProvider) { image in
                    image.scaledToFit()
                } placeholder: {
                    fallbackIcon
                }
                .frame(width: imageSize, height: imageSize)
                .accessibilityHidden(true)
            } else {
                fallbackIcon
            }
        } else {
            Text(reaction.displayKey)
                .font(font)
                .foregroundColor(foregroundColor)
        }
    }
    
    private var fallbackIcon: some View {
        Image(systemName: "photo")
            .resizable()
            .scaledToFit()
            .foregroundColor(foregroundColor)
            .padding(imageSize / 6)
            .frame(width: imageSize, height: imageSize)
            .accessibilityHidden(true)
    }
}
