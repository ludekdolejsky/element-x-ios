//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Synchronization
import Testing

struct NitroGIFServiceTests {
    @Test
    func searchesGIPHYWithConfiguredSafetyAndPagination() async throws {
        let data = Data(#"""
        {
          "data": [{
            "id": "gif-1",
            "title": "Hello GIF",
            "alt_text": "Waving hello",
            "images": {
              "fixed_width_small_still": { "url": "https://media.example.org/still.gif" },
              "fixed_width_small": { "url": "https://media.example.org/preview.gif" },
              "downsized": { "url": "https://media.example.org/download.gif" }
            }
          }],
          "pagination": { "offset": 24, "count": 24, "total_count": 60 }
        }
        """#.utf8)
        let fixture = try MockNitroGIFURLProtocol.makeFixture(statusCode: 200,
                                                              headers: ["Content-Type": "application/json"],
                                                              data: data)
        defer { fixture.remove() }
        let service = makeService(fixture: fixture, resultLimit: 24)

        let page = try await service.search(query: "happy dance", offset: 24).get()

        #expect(page.nextOffset == 48)
        #expect(page.results == [.init(id: "gif-1",
                                       title: "Hello GIF",
                                       altText: "Waving hello",
                                       thumbnailURL: "https://media.example.org/still.gif",
                                       previewURL: "https://media.example.org/preview.gif",
                                       downloadURL: "https://media.example.org/download.gif")])
        let requestURL = try #require(fixture.lastRequest?.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(components.path == "/search")
        #expect(query["api_key"] == "ios-key")
        #expect(query["q"] == "happy dance")
        #expect(query["rating"] == "pg-13")
        #expect(query["limit"] == "24")
        #expect(query["offset"] == "24")
    }

    @Test
    func trendingOmitsResultsWithoutBoundedRendition() async throws {
        let data = Data(#"""
        {
          "data": [{
            "id": "huge",
            "title": "Original only",
            "images": {
              "fixed_width_small_still": { "url": "https://media.example.org/still.gif" },
              "original": { "url": "https://media.example.org/huge.gif" }
            }
          }],
          "pagination": { "offset": 0, "count": 1, "total_count": 1 }
        }
        """#.utf8)
        let fixture = try MockNitroGIFURLProtocol.makeFixture(statusCode: 200,
                                                              headers: ["Content-Type": "application/json"],
                                                              data: data)
        defer { fixture.remove() }
        let service = makeService(fixture: fixture)

        let page = try await service.search(query: "", offset: 0).get()

        #expect(page.results.isEmpty)
        #expect(page.nextOffset == nil)
        #expect(fixture.lastRequest?.url?.path() == "/trending")
    }

    @Test
    func skipsMalformedResultWithoutDiscardingValidResults() async throws {
        let data = Data(#"""
        {
          "data": [{
            "id": "broken",
            "title": "Broken URL",
            "images": {
              "fixed_width_small_still": { "url": "http://[" },
              "fixed_width_small": { "url": "https://media.example.org/preview.gif" },
              "downsized": { "url": "https://media.example.org/download.gif" }
            }
          }, {
            "id": "valid",
            "title": "Valid GIF",
            "images": {
              "fixed_width_small_still": { "url": "https://media.example.org/still.gif" },
              "fixed_width_small": { "url": "https://media.example.org/preview.gif" },
              "downsized": { "url": "https://media.example.org/download.gif" }
            }
          }],
          "pagination": { "offset": 0, "count": 2, "total_count": 2 }
        }
        """#.utf8)
        let fixture = try MockNitroGIFURLProtocol.makeFixture(statusCode: 200,
                                                              headers: ["Content-Type": "application/json"],
                                                              data: data)
        defer { fixture.remove() }
        let service = makeService(fixture: fixture)

        let page = try await service.search(query: "test", offset: 0).get()

        #expect(page.results.map(\.id) == ["valid"])
    }

    @Test
    func rejectsDownloadedNonGIFContent() async throws {
        let fixture = try MockNitroGIFURLProtocol.makeFixture(statusCode: 200,
                                                              headers: ["Content-Type": "text/html"],
                                                              data: Data("not a gif".utf8))
        defer { fixture.remove() }
        let service = makeService(fixture: fixture)

        let result = await service.download(makeResult(downloadURL: fixture.baseURL.appending(path: "file")))

        #expect(result == .failure(.notGIF))
    }

    @Test
    func downloadsGIFToNitroTemporaryDirectory() async throws {
        let fixture = try MockNitroGIFURLProtocol.makeFixture(statusCode: 200,
                                                              headers: ["Content-Type": "image/gif"],
                                                              data: Data("GIF89a".utf8))
        defer { fixture.remove() }
        let root = FileManager.default.temporaryDirectory.appending(path: "nitro-gif-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(fixture: fixture, downloadDirectory: root)

        let url = try await service.download(makeResult(downloadURL: fixture.baseURL.appending(path: "file"))).get()

        #expect(url.pathExtension == "gif")
        #expect(url.path.contains("NitroGiphy"))
        #expect(try Data(contentsOf: url) == Data("GIF89a".utf8))
    }

    private func makeService(fixture: MockNitroGIFURLProtocol.Fixture,
                             resultLimit: Int = 24,
                             downloadDirectory: URL = FileManager.default.temporaryDirectory) -> NitroGIFService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNitroGIFURLProtocol.self]
        return NitroGIFService(configuration: .init(apiKey: "ios-key", rating: .pg13, resultLimit: resultLimit),
                               apiBaseURL: fixture.baseURL,
                               urlSession: URLSession(configuration: configuration),
                               downloadDirectory: downloadDirectory)
    }

    private func makeResult(downloadURL: URL) -> NitroGIFResult {
        .init(id: "gif-1",
              title: "Happy dance",
              altText: "Happy dance",
              thumbnailURL: downloadURL,
              previewURL: downloadURL,
              downloadURL: downloadURL)
    }
}

private final nonisolated class MockNitroGIFURLProtocol: URLProtocol {
    struct Fixture: Sendable {
        fileprivate let identifier: String
        let baseURL: URL

        var lastRequest: URLRequest? {
            MockNitroGIFURLProtocol.states.withLock { $0[identifier]?.lastRequest }
        }

        func remove() {
            MockNitroGIFURLProtocol.states.withLock { $0.removeValue(forKey: identifier) }
        }
    }

    private struct State: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
        var lastRequest: URLRequest?
    }

    private static let states = Mutex([String: State]())

    static func makeFixture(statusCode: Int, headers: [String: String], data: Data) throws -> Fixture {
        let identifier = UUID().uuidString.lowercased() + ".giphy.test"
        let baseURL = try #require(URL(string: "https://\(identifier)"))
        states.withLock {
            $0[identifier] = .init(statusCode: statusCode, headers: headers, data: data)
        }
        return .init(identifier: identifier, baseURL: baseURL)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        states.withLock { $0[request.url?.host() ?? ""] != nil }
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let host = request.url?.host(),
              let state = Self.states.withLock({ states -> State? in
                  guard var state = states[host] else { return nil }
                  state.lastRequest = request
                  states[host] = state
                  return state
              }),
              let url = request.url,
              let response = HTTPURLResponse(url: url,
                                             statusCode: state.statusCode,
                                             httpVersion: nil,
                                             headerFields: state.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: state.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
