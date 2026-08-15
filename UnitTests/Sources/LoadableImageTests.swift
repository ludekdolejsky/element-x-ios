//
// Copyright 2026 Element Creations Ltd.
// Copyright 2026 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import ImageIO
import Testing

@MainActor
struct LoadableImageTests {
    @Test
    func animationEnabledLoadsOriginalDataWithoutMIMEType() async throws {
        let animatedGIF = try #require(Data(base64Encoded: "R0lGODlhAgACAPAAAP8AAAAAACH5BAAKAAAAIf8LTkVUU0NBUEUyLjADAQAAACwAAAAAAgACAAACAoRRACH5BAAKAAAALAAAAAACAAIAgAAA/wAAAAIChFEAOw=="))
        let imageSource = try #require(CGImageSourceCreateWithData(animatedGIF as CFData, nil))
        #expect(CGImageSourceGetCount(imageSource) == 2)
        
        let mediaProvider = MediaProviderMock(.init())
        mediaProvider.loadImageDataFromSourceClosure = { _ in .success(animatedGIF) }
        let mediaSource = try MediaSourceProxy(url: "mxc://example.org/animated-emoji", mimeType: nil)
        let loader = LoadableImageContentLoader(mediaSource: mediaSource,
                                                size: CGSize(width: 36, height: 36),
                                                allowsAnimation: true,
                                                mediaProvider: mediaProvider)
        
        await loader.load()
        
        #expect(mediaProvider.loadImageDataFromSourceCallsCount == 1)
        #expect(mediaProvider.loadImageRetryingOnReconnectionSizeCallsCount == 0)
        guard case .imageData(let loadedData) = loader.content else {
            Issue.record("Expected original image data for an animation-enabled image")
            return
        }
        #expect(loadedData == animatedGIF)
    }
}
