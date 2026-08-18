//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Kingfisher
import UIKit

private actor ImageDataCache {
    private let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    
    func data(for key: String) -> Data? {
        cache.object(forKey: key as NSString).map { Data(referencing: $0) }
    }
    
    func store(_ data: Data, for key: String) {
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
}

nonisolated struct MediaProvider: MediaProviderProtocol {
    private let mediaLoader: MediaLoaderProtocol
    private let imageCache: Kingfisher.ImageCache
    private let imageDataCache = ImageDataCache()
    private let homeserverReachabilityPublisher: CurrentValuePublisher<HomeserverReachability, Never>?
    
    init(mediaLoader: MediaLoaderProtocol,
         imageCache: Kingfisher.ImageCache,
         homeserverReachabilityPublisher: CurrentValuePublisher<HomeserverReachability, Never>?) {
        self.mediaLoader = mediaLoader
        self.imageCache = imageCache
        self.homeserverReachabilityPublisher = homeserverReachabilityPublisher
    }
    
    // MARK: Images
    
    func imageFromSource(_ source: MediaSourceProxy?, size: CGSize?) -> UIImage? {
        guard let url = source?.url else {
            return nil
        }
        let cacheKey = cacheKeyForURL(url, size: size)
        return imageCache.retrieveImageInMemoryCache(forKey: cacheKey, options: nil)
    }
    
    func loadImageFromSource(_ source: MediaSourceProxy, size: CGSize?) async -> Result<UIImage, MediaProviderError> {
        if let image = imageFromSource(source, size: size) {
            return .success(image)
        }
        
        let cacheKey = cacheKeyForURL(source.url, size: size)
        
        if let cacheResult = try? await imageCache.retrieveImage(forKey: cacheKey, options: nil),
           let image = cacheResult.image {
            return .success(image)
        }
        
        do {
            let imageData: Data
            if let size {
                imageData = try await mediaLoader.loadMediaThumbnailForSource(source, width: UInt(size.width), height: UInt(size.height))
            } else {
                imageData = try await mediaLoader.loadMediaContentForSource(source)
            }
            
            guard let image = UIImage(data: imageData) else {
                MXLog.error("Invalid image data")
                return .failure(.invalidImageData)
            }
            
            try await imageCache.store(image, forKey: cacheKey)
            
            return .success(image)
        } catch {
            MXLog.error("Failed retrieving image with error: \(error)")
            return .failure(.failedRetrievingImage)
        }
    }
    
    func loadImageRetryingOnReconnection(_ source: MediaSourceProxy, size: CGSize?) -> Task<UIImage, any Error> {
        guard let homeserverReachabilityPublisher else {
            fatalError("This method shouldn't be invoked without a homeserver reachability publisher set.")
        }
        
        return Task {
            if case let .success(image) = await loadImageFromSource(source, size: size) {
                return image
            }
            
            guard !Task.isCancelled else {
                throw MediaProviderError.cancelled
            }
            
            for await reachability in homeserverReachabilityPublisher.values {
                guard !Task.isCancelled else {
                    throw MediaProviderError.cancelled
                }
                
                guard reachability == .reachable else {
                    continue
                }
                
                switch await loadImageFromSource(source, size: size) {
                case .success(let image):
                    return image
                case .failure:
                    // If it fails after a retry with the network available
                    // then something else must be wrong. Bail out.
                    if reachability == .reachable {
                        throw MediaProviderError.cancelled
                    }
                }
            }
            
            throw MediaProviderError.cancelled
        }
    }
    
    func loadImageDataFromSource(_ source: MediaSourceProxy) async -> Result<Data, MediaProviderError> {
        let initialResult = await loadImageDataOnce(from: source)
        guard case .failure(.failedRetrievingImage) = initialResult,
              let homeserverReachabilityPublisher else {
            return initialResult
        }
        
        for await reachability in homeserverReachabilityPublisher.values {
            guard !Task.isCancelled else { return .failure(.cancelled) }
            guard reachability == .reachable else { continue }
            return await loadImageDataOnce(from: source)
        }
        
        return Task.isCancelled ? .failure(.cancelled) : initialResult
    }
    
    private func loadImageDataOnce(from source: MediaSourceProxy) async -> Result<Data, MediaProviderError> {
        let cacheKey = source.url.absoluteString
        if let imageData = await imageDataCache.data(for: cacheKey) {
            return .success(imageData)
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        
        do {
            let imageData = try await mediaLoader.loadMediaContentForSource(source)
            guard !Task.isCancelled else { return .failure(.cancelled) }
            await imageDataCache.store(imageData, for: cacheKey)
            return .success(imageData)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            guard !Task.isCancelled else { return .failure(.cancelled) }
            MXLog.error("Failed retrieving image with error: \(error)")
            return .failure(.failedRetrievingImage)
        }
    }
    
    // MARK: Files
    
    func loadFileFromSource(_ source: MediaSourceProxy, filename: String?) async -> Result<MediaFileHandleProxy, MediaProviderError> {
        do {
            let file = try await mediaLoader.loadMediaFileForSource(source, filename: filename)
            return .success(file)
        } catch {
            MXLog.error("Failed retrieving file with error: \(error)")
            return .failure(.failedRetrievingFile)
        }
    }
    
    // MARK: Thumbnail
    
    func loadThumbnailForSource(source: MediaSourceProxy, size: CGSize) async -> Result<Data, MediaProviderError> {
        do {
            let thumbnailData = try await mediaLoader.loadMediaThumbnailForSource(source, width: UInt(size.width), height: UInt(size.height))
            return .success(thumbnailData)
        } catch {
            MXLog.error("Failed retrieving image with error: \(error)")
            return .failure(.failedRetrievingThumbnail)
        }
    }
    
    // MARK: - Private
    
    private func cacheKeyForURL(_ url: URL, size: CGSize?) -> String {
        if let size {
            return "\(url.absoluteString){\(size.width),\(size.height)}"
        } else {
            return url.absoluteString
        }
    }
}
