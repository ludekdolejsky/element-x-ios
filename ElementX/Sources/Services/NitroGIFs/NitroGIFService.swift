//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated enum NitroGIFRating: String, Sendable {
    case general = "g"
    case parentalGuidance = "pg"
    case pg13 = "pg-13"
    case restricted = "r"
}

nonisolated struct NitroGIFConfiguration: Equatable, Sendable {
    let apiKey: String
    let rating: NitroGIFRating
    let resultLimit: Int
}

nonisolated struct NitroGIFResult: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let altText: String
    let thumbnailURL: URL
    let previewURL: URL
    let downloadURL: URL
}

nonisolated struct NitroGIFSearchPage: Equatable, Sendable {
    let results: [NitroGIFResult]
    let nextOffset: Int?
}

nonisolated enum NitroGIFServiceError: Error, Equatable, Sendable {
    case cancelled
    case httpError(statusCode: Int)
    case invalidResponse
    case notGIF
    case tooLarge
    case network
}

nonisolated protocol NitroGIFServiceProtocol: Sendable {
    func search(query: String, offset: Int) async -> Result<NitroGIFSearchPage, NitroGIFServiceError>
    func download(_ result: NitroGIFResult) async -> Result<URL, NitroGIFServiceError>
}

nonisolated struct NitroGIFService: NitroGIFServiceProtocol {
    private enum Constants {
        static let apiBaseURL: URL = "https://api.giphy.com/v1/gifs"
        static let maximumResultLimit = 50
        static let maximumGIFSize = 20 * 1024 * 1024
        static let downloadDirectoryName = "NitroGiphy"
        static let downloadLifetime: TimeInterval = 24 * 60 * 60
    }

    private let configuration: NitroGIFConfiguration
    private let apiBaseURL: URL
    private let urlSession: URLSession
    private let downloadDirectory: URL
    private let now: @Sendable () -> Date

    init(configuration: NitroGIFConfiguration,
         apiBaseURL: URL = Constants.apiBaseURL,
         urlSession: URLSession = .shared,
         downloadDirectory: URL = FileManager.default.temporaryDirectory,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.configuration = configuration
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.downloadDirectory = downloadDirectory.appending(path: Constants.downloadDirectoryName, directoryHint: .isDirectory)
        self.now = now
    }

    func search(query: String, offset: Int = 0) async -> Result<NitroGIFSearchPage, NitroGIFServiceError> {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = trimmedQuery.isEmpty ? "trending" : "search"
        let limit = min(Constants.maximumResultLimit, max(1, configuration.resultLimit))
        var components = URLComponents(url: apiBaseURL.appending(path: endpoint), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "api_key", value: configuration.apiKey),
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(max(0, offset))),
            .init(name: "rating", value: configuration.rating.rawValue)
        ]
        if !trimmedQuery.isEmpty {
            components?.queryItems?.append(.init(name: "q", value: trimmedQuery))
        }

        guard let url = components?.url else { return .failure(.invalidResponse) }

        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let response = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
            guard 200..<300 ~= response.statusCode else { return .failure(.httpError(statusCode: response.statusCode)) }

            let payload = try JSONDecoder().decode(GIPHYResponse.self, from: data)
            let results = payload.data.compactMap(NitroGIFResult.init)
            let pagination = payload.pagination
            let nextOffset = pagination.count > 0 && pagination.offset + pagination.count < pagination.totalCount
                ? pagination.offset + pagination.count
                : nil
            return .success(.init(results: results, nextOffset: nextOffset))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch is DecodingError {
            return .failure(.invalidResponse)
        } catch {
            return .failure(.network)
        }
    }

    func download(_ result: NitroGIFResult) async -> Result<URL, NitroGIFServiceError> {
        do {
            let (temporaryURL, response) = try await urlSession.download(from: result.downloadURL)
            guard let response = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
            guard 200..<300 ~= response.statusCode else { return .failure(.httpError(statusCode: response.statusCode)) }
            guard response.mimeType?.lowercased() == "image/gif" else { return .failure(.notGIF) }
            if response.expectedContentLength > Constants.maximumGIFSize {
                return .failure(.tooLarge)
            }

            let fileSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= Constants.maximumGIFSize else { return .failure(.tooLarge) }

            try prepareDownloadDirectory()
            let destinationURL = downloadDirectory
                .appending(path: "\(UUID().uuidString)-\(safeFilenameStem(for: result))", directoryHint: .notDirectory)
                .appendingPathExtension("gif")
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            return .success(destinationURL)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch {
            return .failure(.network)
        }
    }

    private func prepareDownloadDirectory() throws {
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let cutoff = now().addingTimeInterval(-Constants.downloadLifetime)
        let files = try FileManager.default.contentsOfDirectory(at: downloadDirectory,
                                                                includingPropertiesForKeys: [.creationDateKey],
                                                                options: .skipsHiddenFiles)
        for file in files where (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast < cutoff {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func safeFilenameStem(for result: NitroGIFResult) -> String {
        let foldedTitle = result.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let components = foldedTitle.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let title = components.joined(separator: "-").prefix(64)
        return title.isEmpty ? "giphy-\(result.id)" : String(title)
    }
}

private nonisolated extension NitroGIFResult {
    init?(_ result: NitroGIFService.GIPHYResult) {
        guard let id = result.id?.nonEmpty,
              let thumbnailURL = result.images.fixedWidthSmallStill?.url
              ?? result.images.fixedWidthStill?.url
              ?? result.images.downsizedStill?.url,
              let previewURL = result.images.fixedWidthSmall?.url
              ?? result.images.fixedWidth?.url
              ?? result.images.downsized?.url,
              let downloadURL = result.images.downsized?.url else {
            return nil
        }

        let title = result.title?.nonEmpty ?? "GIF"
        self.init(id: id,
                  title: title,
                  altText: result.altText?.nonEmpty ?? title,
                  thumbnailURL: thumbnailURL,
                  previewURL: previewURL,
                  downloadURL: downloadURL)
    }
}

private nonisolated extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private nonisolated extension NitroGIFService {
    struct GIPHYResponse: Decodable {
        let data: [GIPHYResult]
        let pagination: GIPHYPagination
    }

    struct GIPHYResult: Decodable {
        let id: String?
        let title: String?
        let altText: String?
        let images: GIPHYImages

        enum CodingKeys: String, CodingKey {
            case id, title, images
            case altText = "alt_text"
        }
    }

    struct GIPHYImages: Decodable {
        let fixedWidthSmallStill: GIPHYImage?
        let fixedWidthStill: GIPHYImage?
        let downsizedStill: GIPHYImage?
        let fixedWidthSmall: GIPHYImage?
        let fixedWidth: GIPHYImage?
        let downsized: GIPHYImage?

        enum CodingKeys: String, CodingKey {
            case fixedWidthSmallStill = "fixed_width_small_still"
            case fixedWidthStill = "fixed_width_still"
            case downsizedStill = "downsized_still"
            case fixedWidthSmall = "fixed_width_small"
            case fixedWidth = "fixed_width"
            case downsized
        }
    }

    struct GIPHYImage: Decodable {
        let url: URL?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let value = try container.decodeIfPresent(String.self, forKey: .url)
            url = value.flatMap(URL.init(string:))
        }

        private enum CodingKeys: CodingKey {
            case url
        }
    }

    struct GIPHYPagination: Decodable {
        let offset: Int
        let count: Int
        let totalCount: Int

        enum CodingKeys: String, CodingKey {
            case offset, count
            case totalCount = "total_count"
        }
    }
}
