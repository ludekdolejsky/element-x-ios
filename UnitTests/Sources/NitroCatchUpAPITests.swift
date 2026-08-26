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

struct NitroCatchUpAPITests {
    @Test
    func mapsPayloadTooLargeResponse() async throws {
        let fixture = try MockNitroCatchUpURLProtocol.makeFixture(statusCode: 413, data: Data())
        defer { fixture.remove() }
        let api = NitroCatchUpAPI(baseURL: fixture.baseURL, urlSession: makeURLSession())
        
        await #expect(throws: NitroCatchUpServiceError.rangeTooLarge) {
            _ = try await api.start(requestID: "request",
                                    roomID: "!room:example.org",
                                    roomName: "Nitro team",
                                    mode: .overview,
                                    messages: [message(body: "Hello")],
                                    authentication: authentication)
        }
    }
    
    @Test
    func preservesBackendErrorMessage() async throws {
        let data = try JSONEncoder().encode(["error": "Daily catch up limit reached."])
        let fixture = try MockNitroCatchUpURLProtocol.makeFixture(statusCode: 429, data: data)
        defer { fixture.remove() }
        let api = NitroCatchUpAPI(baseURL: fixture.baseURL, urlSession: makeURLSession())
        
        await #expect(throws: NitroCatchUpAPIError.httpStatus(429, message: "Daily catch up limit reached.")) {
            _ = try await api.start(requestID: "request",
                                    roomID: "!room:example.org",
                                    roomName: "Nitro team",
                                    mode: .overview,
                                    messages: [message(body: "Hello")],
                                    authentication: authentication)
        }
    }
    
    @Test
    func rejectsOversizedRequestBeforeSendingIt() async throws {
        let fixture = try MockNitroCatchUpURLProtocol.makeFixture(statusCode: 200, data: Data())
        defer { fixture.remove() }
        let api = NitroCatchUpAPI(baseURL: fixture.baseURL, urlSession: makeURLSession())
        
        await #expect(throws: NitroCatchUpServiceError.rangeTooLarge) {
            _ = try await api.start(requestID: "request",
                                    roomID: "!room:example.org",
                                    roomName: "Nitro team",
                                    mode: .overview,
                                    messages: [message(body: String(repeating: "x", count: NitroCatchUpRequestLimits.maximumRequestByteCount))],
                                    authentication: authentication)
        }
        #expect(fixture.lastRequest == nil)
    }
    
    @Test
    func messageBufferRejectsOversizedHistory() throws {
        var buffer = NitroCatchUpMessageBuffer()
        let largeMessage = message(body: String(repeating: "x", count: 50000))
        
        #expect(throws: NitroCatchUpServiceError.rangeTooLarge) {
            for _ in 0..<100 {
                try buffer.append(largeMessage)
            }
        }
        #expect(!buffer.messages.isEmpty)
    }
    
    private var authentication: NitroCatchUpAuthentication {
        .init(homeserverURL: "https://matrix.example.org",
              openIDToken: .init(accessToken: "token", tokenType: "Bearer", matrixServerName: "example.org"))
    }
    
    private func message(body: String) -> NitroCatchUpMessage {
        .init(eventID: "$event",
              sender: "Alice",
              senderID: "@alice:example.org",
              timestamp: "2026-08-25T12:00:00Z",
              body: body,
              permalink: "https://matrix.to/#/!room:example.org/$event",
              threadRootID: nil)
    }
    
    private func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNitroCatchUpURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final nonisolated class MockNitroCatchUpURLProtocol: URLProtocol {
    struct Fixture: Sendable {
        fileprivate let identifier: String
        let baseURL: URL
        
        var lastRequest: URLRequest? {
            MockNitroCatchUpURLProtocol.states.withLock { $0[identifier]?.lastRequest }
        }
        
        func remove() {
            _ = MockNitroCatchUpURLProtocol.states.withLock { $0.removeValue(forKey: identifier) }
        }
    }
    
    private struct State: Sendable {
        let statusCode: Int
        let data: Data
        var lastRequest: URLRequest?
    }
    
    private static let states = Mutex([String: State]())
    
    static func makeFixture(statusCode: Int, data: Data) throws -> Fixture {
        let identifier = UUID().uuidString.lowercased() + ".matrix-bot.nitrovery.com"
        let baseURL = try #require(URL(string: "https://\(identifier)"))
        states.withLock {
            $0[identifier] = .init(statusCode: statusCode, data: data)
        }
        return .init(identifier: identifier, baseURL: baseURL)
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
