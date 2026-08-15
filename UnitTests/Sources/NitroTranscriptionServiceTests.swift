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

struct NitroTranscriptionServiceTests {
    @Test
    func transcribesAudioWithOpenIDHeaders() async throws {
        let fixture = try MockNitroTranscriptionURLProtocol.makeFixture(statusCode: 200, data: Data(#"{"text":"  Hello from audio.  "}"#.utf8))
        defer { fixture.remove() }
        let service = NitroTranscriptionService(baseURL: fixture.baseURL, urlSession: makeURLSession())
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        
        let result = await service.transcribeAudio(at: fileURL,
                                                   filename: "Voice note ü.m4a",
                                                   contentType: "audio/mp4",
                                                   homeserverURL: "https://matrix.example.org",
                                                   openIDToken: .init(accessToken: "secret-token",
                                                                      tokenType: "Bearer",
                                                                      matrixServerName: "example.org"))
        
        #expect(try result.get() == "Hello from audio.")
        let request = try #require(fixture.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/transcribe")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
        #expect(request.value(forHTTPHeaderField: "X-Homeserver-Url") == "https://matrix.example.org")
        #expect(request.value(forHTTPHeaderField: "X-Filename") == "Voice%20note%20%C3%BC.m4a")
        #expect(request.value(forHTTPHeaderField: "X-Openid-Access-Token") == "secret-token")
        #expect(request.value(forHTTPHeaderField: "X-Openid-Token-Type") == "Bearer")
        #expect(request.value(forHTTPHeaderField: "X-Openid-Matrix-Server-Name") == "example.org")
    }
    
    @Test
    func returnsHTTPErrorWithoutDecodingBody() async throws {
        let fixture = try MockNitroTranscriptionURLProtocol.makeFixture(statusCode: 503, data: Data(#"{"error":"unavailable"}"#.utf8))
        defer { fixture.remove() }
        let service = NitroTranscriptionService(baseURL: fixture.baseURL, urlSession: makeURLSession())
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        
        let result = await service.transcribeAudio(at: fileURL,
                                                   filename: "voice.m4a",
                                                   contentType: "audio/mp4",
                                                   homeserverURL: "https://matrix.example.org",
                                                   openIDToken: .init(accessToken: "token",
                                                                      tokenType: "Bearer",
                                                                      matrixServerName: "example.org"))
        
        #expect(result == .failure(.httpError(statusCode: 503)))
    }
    
    @Test
    func rejectsEmptyTranscript() async throws {
        let fixture = try MockNitroTranscriptionURLProtocol.makeFixture(statusCode: 200, data: Data(#"{"text":"  \n "}"#.utf8))
        defer { fixture.remove() }
        let service = NitroTranscriptionService(baseURL: fixture.baseURL, urlSession: makeURLSession())
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        
        let result = await service.transcribeAudio(at: fileURL,
                                                   filename: "voice.m4a",
                                                   contentType: "audio/mp4",
                                                   homeserverURL: "https://matrix.example.org",
                                                   openIDToken: .init(accessToken: "token",
                                                                      tokenType: "Bearer",
                                                                      matrixServerName: "example.org"))
        
        #expect(result == .failure(.emptyTranscript))
    }
    
    private func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNitroTranscriptionURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    
    private func makeAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "nitro-transcription-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: url)
        return url
    }
}

private final nonisolated class MockNitroTranscriptionURLProtocol: URLProtocol {
    struct Fixture: Sendable {
        fileprivate let identifier: String
        let baseURL: URL
        
        var lastRequest: URLRequest? {
            MockNitroTranscriptionURLProtocol.states.withLock { $0[identifier]?.lastRequest }
        }
        
        func remove() {
            MockNitroTranscriptionURLProtocol.states.withLock { $0.removeValue(forKey: identifier) }
        }
    }
    
    private struct State: Sendable {
        let statusCode: Int
        let data: Data
        var lastRequest: URLRequest?
    }
    
    private static let states = Mutex([String: State]())
    
    static func makeFixture(statusCode: Int, data: Data) throws -> Fixture {
        let identifier = UUID().uuidString.lowercased()
        let baseURL = try #require(URL(string: "https://\(identifier).matrix-bot.nitrovery.com"))
        states.withLock {
            $0[identifier + ".matrix-bot.nitrovery.com"] = .init(statusCode: statusCode, data: data)
        }
        return .init(identifier: identifier + ".matrix-bot.nitrovery.com", baseURL: baseURL)
    }
    
    override func startLoading() {
        let responseState = Self.states.withLock { states -> (Int, Data)? in
            guard let identifier = request.url?.host(), var state = states[identifier] else { return nil }
            state.lastRequest = request
            states[identifier] = state
            return (state.statusCode, state.data)
        }
        
        guard let responseState,
              let url = request.url,
              let response = HTTPURLResponse(url: url,
                                             statusCode: responseState.0,
                                             httpVersion: nil,
                                             headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseState.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    
    override func stopLoading() { }
    
    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }
    
    override static func canInit(with request: URLRequest) -> Bool {
        true
    }
}
