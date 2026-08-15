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

struct NitroReminderServiceTests {
    @Test
    func createsReminderUsingDesktopCompatiblePayload() async throws {
        let fixture = try MockNitroReminderURLProtocol.makeFixture(statusCode: 201,
                                                                   data: Data(#"{"ok":true,"id":"reminder-1","due_ts":1800000000}"#.utf8))
        defer { fixture.remove() }
        let service = NitroReminderService(baseURL: fixture.baseURL, urlSession: makeURLSession())
        let schedule = NitroReminderSchedule(target: .init(roomID: "!room:example.org",
                                                           roomName: "Nitro team",
                                                           eventID: "$event:example.org",
                                                           threadRootID: "$root:example.org",
                                                           permalink: "https://matrix.to/#/!room:example.org/$event:example.org"),
                                             dueDate: Date(timeIntervalSince1970: 1_800_000_000),
                                             label: "in 20 minutes")
        
        let result = await service.createReminder(schedule, authentication: authentication)
        
        #expect(try result.get() == .init(id: "reminder-1", dueDate: Date(timeIntervalSince1970: 1_800_000_000)))
        let request = try #require(fixture.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/reminders")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["homeserver_url"] as? String == "https://matrix.example.org")
        #expect(json["room_id"] as? String == "!room:example.org")
        #expect(json["room_name"] as? String == "Nitro team")
        #expect(json["event_id"] as? String == "$event:example.org")
        #expect(json["thread_root_id"] as? String == "$root:example.org")
        #expect(json["due_ts"] as? Int == 1_800_000_000)
        #expect(json["label"] as? String == "in 20 minutes")
        #expect(json["permalink"] as? String == "https://matrix.to/#/!room:example.org/$event:example.org")
        #expect(json["idempotency_key"] as? String == #"["!room:example.org","$event:example.org","$root:example.org",1800000000]"#)
        let token = try #require(json["openid_token"] as? [String: String])
        #expect(token["access_token"] == "secret-token")
        #expect(token["token_type"] == "Bearer")
        #expect(token["matrix_server_name"] == "example.org")
    }
    
    @Test
    func listsAndDecodesReminders() async throws {
        let data = Data(#"""
        {
          "ok": true,
          "now_ts": 1700000100,
          "reminders": [{
            "id": "reminder-1",
            "user_id": "@alice:example.org",
            "homeserver_url": "https://matrix.example.org",
            "room_id": "!room:example.org",
            "room_name": "Nitro team",
            "event_id": "$event:example.org",
            "thread_root_id": null,
            "due_ts": 1700000200,
            "label": "in 20 minutes",
            "permalink": "https://matrix.to/#/!room:example.org/$event:example.org",
            "created_ts": 1700000000,
            "delivered_ts": null,
            "updated_ts": 1700000000,
            "status": "pending",
            "error": null
          }]
        }
        """#.utf8)
        let fixture = try MockNitroReminderURLProtocol.makeFixture(statusCode: 200, data: data)
        defer { fixture.remove() }
        let service = NitroReminderService(baseURL: fixture.baseURL, urlSession: makeURLSession())
        
        let result = try await service.reminders(filter: .upcoming, authentication: authentication).get()
        
        #expect(result.now == Date(timeIntervalSince1970: 1_700_000_100))
        let reminder = try #require(result.reminders.first)
        #expect(reminder.id == "reminder-1")
        #expect(reminder.userID == "@alice:example.org")
        #expect(reminder.roomName == "Nitro team")
        #expect(reminder.status == .pending)
        let request = try #require(fixture.lastRequest)
        #expect(request.url?.path() == "/api/reminders/list")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["status"] as? String == "upcoming")
    }
    
    @Test
    func includesBackendErrorMessage() async throws {
        let fixture = try MockNitroReminderURLProtocol.makeFixture(statusCode: 400,
                                                                   data: Data(#"{"error":"due_ts is in the past"}"#.utf8))
        defer { fixture.remove() }
        let service = NitroReminderService(baseURL: fixture.baseURL, urlSession: makeURLSession())
        
        let result = await service.deleteReminder(reminderID: "reminder-1", authentication: authentication)
        
        switch result {
        case .success:
            Issue.record("Expected the backend request to fail.")
        case .failure(let error):
            #expect(error == .httpError(statusCode: 400, message: "due_ts is in the past"))
        }
        #expect(fixture.lastRequest?.url?.path() == "/api/reminders/reminder-1/delete")
    }
    
    private var authentication: NitroReminderAuthentication {
        .init(homeserverURL: "https://matrix.example.org",
              openIDToken: .init(accessToken: "secret-token",
                                 tokenType: "Bearer",
                                 matrixServerName: "example.org"))
    }
    
    private func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNitroReminderURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final nonisolated class MockNitroReminderURLProtocol: URLProtocol {
    struct Fixture: Sendable {
        fileprivate let identifier: String
        let baseURL: URL
        
        var lastRequest: URLRequest? {
            MockNitroReminderURLProtocol.states.withLock { $0[identifier]?.lastRequest }
        }
        
        func remove() {
            _ = MockNitroReminderURLProtocol.states.withLock { $0.removeValue(forKey: identifier) }
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
            let count = stream.read(&buffer, maxLength: 4096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
