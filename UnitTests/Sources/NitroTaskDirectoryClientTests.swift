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

struct NitroTaskDirectoryClientTests {
    @Test
    func returnsOnlyExplicitlyRequestedHints() async throws {
        let data = Data(#"""
        {
          "entries": [
            {"room_id":"!room:example.org","task_event_id":"$task:example.org","content_event_id":"$edit:example.org","content_origin_ts":100,"state_event_id":"$state:example.org","state_origin_ts":200,"revision":3,"fresh":true},
            {"room_id":"!other:example.org","task_event_id":"$other:example.org","content_event_id":"$other:example.org","content_origin_ts":1,"state_event_id":null,"state_origin_ts":null,"revision":1,"fresh":true}
          ]
        }
        """#.utf8)
        let fixture = try MockNitroTaskDirectoryURLProtocol.makeFixture(statusCode: 200, data: data)
        defer { fixture.remove() }
        let client = NitroTaskDirectoryClient(baseURL: fixture.baseURL, urlSession: makeURLSession())
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        
        let result = try await client.resolve([key], authentication: authentication)
        
        #expect(result.count == 1)
        #expect(result[key]?.contentEventID == "$edit:example.org")
        let request = try #require(fixture.lastRequest)
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tasks = try #require(object["tasks"] as? [[String: Any]])
        #expect(tasks.count == 1)
        #expect(tasks.first?["room_id"] as? String == "!room:example.org")
        #expect(tasks.first?["task_event_id"] as? String == "$task:example.org")
        #expect(body.range(of: Data("title".utf8)) == nil)
        #expect(body.range(of: Data("description".utf8)) == nil)
        #expect(request.url?.path() == "/api/task-directory/resolve")
    }
    
    @Test
    func rejectsMalformedHintAndFallsBack() async throws {
        let data = Data(#"{"entries":[{"room_id":"!room:example.org","task_event_id":"$task:example.org","content_event_id":"invalid","content_origin_ts":100,"state_event_id":null,"state_origin_ts":null,"revision":1,"fresh":true}]}"#.utf8)
        let fixture = try MockNitroTaskDirectoryURLProtocol.makeFixture(statusCode: 200, data: data)
        defer { fixture.remove() }
        let client = NitroTaskDirectoryClient(baseURL: fixture.baseURL, urlSession: makeURLSession())
        
        await #expect(throws: NitroTaskDirectoryError.invalidResponse) {
            _ = try await client.resolve([.init(roomID: "!room:example.org", taskEventID: "$task:example.org")],
                                         authentication: authentication)
        }
    }
    
    @Test
    func rejectsDuplicateHintsForARequestedTask() async throws {
        let entry = #"{"room_id":"!room:example.org","task_event_id":"$task:example.org","content_event_id":"$task:example.org","content_origin_ts":100,"state_event_id":null,"state_origin_ts":null,"revision":1,"fresh":true}"#
        let fixture = try MockNitroTaskDirectoryURLProtocol.makeFixture(statusCode: 200,
                                                                        data: Data("{\"entries\":[\(entry),\(entry)]}".utf8))
        defer { fixture.remove() }
        let client = NitroTaskDirectoryClient(baseURL: fixture.baseURL, urlSession: makeURLSession())
        
        await #expect(throws: NitroTaskDirectoryError.invalidResponse) {
            _ = try await client.resolve([.init(roomID: "!room:example.org", taskEventID: "$task:example.org")],
                                         authentication: authentication)
        }
    }
    
    @Test
    func encodesAuthoritativeNoStateWithoutPlaintext() async throws {
        let data = Data(#"{"entries":[{"room_id":"!room:example.org","task_event_id":"$task:example.org","revision":1,"applied":true,"conflict":false}]}"#.utf8)
        let fixture = try MockNitroTaskDirectoryURLProtocol.makeFixture(statusCode: 200, data: data)
        defer { fixture.remove() }
        let client = NitroTaskDirectoryClient(baseURL: fixture.baseURL, urlSession: makeURLSession())
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        
        _ = try await client.update([.init(key: key,
                                           contentEventID: "$task:example.org",
                                           contentOriginTimestamp: 100,
                                           statePointer: NitroTaskDirectoryStatePointer.none,
                                           isAuthoritative: true)],
                                    authentication: authentication)
        
        let body = try #require(fixture.lastRequest?.httpBody)
        let string = try #require(String(data: body, encoding: .utf8))
        #expect(string.contains(#""state_event_id":null"#))
        #expect(string.contains(#""state_origin_ts":null"#))
        #expect(!string.contains("status"))
        #expect(!string.contains("assignee"))
    }
    
    @Test
    func acceptsNoOpInvalidationForUnknownTask() async throws {
        let data = Data(#"{"entries":[{"room_id":"!room:example.org","task_event_id":"$task:example.org","revision":0,"applied":true,"conflict":false}]}"#.utf8)
        let fixture = try MockNitroTaskDirectoryURLProtocol.makeFixture(statusCode: 200, data: data)
        defer { fixture.remove() }
        let client = NitroTaskDirectoryClient(baseURL: fixture.baseURL, urlSession: makeURLSession())
        let key = NitroTaskDirectoryKey(roomID: "!room:example.org", taskEventID: "$task:example.org")
        
        let results = try await client.update([.init(key: key, invalidates: true)], authentication: authentication)
        
        let result = try #require(results.first)
        #expect(result.key == key)
        #expect(result.revision == 0)
        #expect(result.isApplied)
        #expect(!result.hasConflict)
    }
    
    private var authentication: NitroTaskDirectoryAuthentication {
        .init(homeserverURL: "https://matrix.example.org",
              openIDToken: .init(accessToken: "token", tokenType: "Bearer", matrixServerName: "example.org"))
    }
    
    private func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNitroTaskDirectoryURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final nonisolated class MockNitroTaskDirectoryURLProtocol: URLProtocol {
    struct Fixture: Sendable {
        fileprivate let identifier: String
        let baseURL: URL
        
        var lastRequest: URLRequest? {
            MockNitroTaskDirectoryURLProtocol.states.withLock { $0[identifier]?.lastRequest }
        }
        
        func remove() {
            _ = MockNitroTaskDirectoryURLProtocol.states.withLock { $0.removeValue(forKey: identifier) }
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
        states.withLock { $0[identifier] = .init(statusCode: statusCode, data: data) }
        return .init(identifier: identifier, baseURL: baseURL)
    }
    
    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let bodyStream = capturedRequest.httpBodyStream {
            capturedRequest.httpBody = Self.readData(from: bodyStream)
        }
        let responseState = Self.states.withLock { states -> (Int, Data)? in
            guard let identifier = request.url?.host(), var state = states[identifier] else { return nil }
            state.lastRequest = capturedRequest
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
    
    private static func readData(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
