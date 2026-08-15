//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated struct NitroReminderService: NitroReminderServiceProtocol {
    private struct OpenIDTokenPayload: Encodable, Sendable {
        let accessToken: String
        let tokenType: String
        let matrixServerName: String
        
        init(token: NitroOpenIDToken) {
            accessToken = token.accessToken
            tokenType = token.tokenType
            matrixServerName = token.matrixServerName
        }
        
        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case matrixServerName = "matrix_server_name"
        }
    }
    
    private struct CreateRequest: Encodable, Sendable {
        let homeserverURL: String
        let openIDToken: OpenIDTokenPayload
        let roomID: String
        let roomName: String
        let eventID: String
        let threadRootID: String?
        let dueTimestamp: Int
        let label: String
        let permalink: String
        let idempotencyKey: String
        
        init?(schedule: NitroReminderSchedule, authentication: NitroReminderAuthentication) {
            let dueTimestamp = Int(schedule.dueDate.timeIntervalSince1970)
            guard let idempotencyKey = Self.makeIdempotencyKey(schedule: schedule, dueTimestamp: dueTimestamp) else {
                return nil
            }
            
            homeserverURL = authentication.homeserverURL.absoluteString
            openIDToken = .init(token: authentication.openIDToken)
            roomID = schedule.target.roomID
            roomName = schedule.target.roomName
            eventID = schedule.target.eventID
            threadRootID = schedule.target.threadRootID
            self.dueTimestamp = dueTimestamp
            label = schedule.label
            permalink = schedule.target.permalink.absoluteString
            self.idempotencyKey = idempotencyKey
        }
        
        private enum CodingKeys: String, CodingKey {
            case homeserverURL = "homeserver_url"
            case openIDToken = "openid_token"
            case roomID = "room_id"
            case roomName = "room_name"
            case eventID = "event_id"
            case threadRootID = "thread_root_id"
            case dueTimestamp = "due_ts"
            case label
            case permalink
            case idempotencyKey = "idempotency_key"
        }
        
        private static func makeIdempotencyKey(schedule: NitroReminderSchedule, dueTimestamp: Int) -> String? {
            let threadRootID: Any = if let value = schedule.target.threadRootID {
                value
            } else {
                NSNull()
            }
            let components: [Any] = [schedule.target.roomID,
                                     schedule.target.eventID,
                                     threadRootID,
                                     dueTimestamp]
            guard let data = try? JSONSerialization.data(withJSONObject: components, options: .withoutEscapingSlashes) else {
                return nil
            }
            return String(bytes: data, encoding: .utf8)
        }
    }
    
    private struct CreateResponse: Decodable, Sendable {
        let id: String
        let dueTimestamp: Int
        
        private enum CodingKeys: String, CodingKey {
            case id
            case dueTimestamp = "due_ts"
        }
    }
    
    private struct ListRequest: Encodable, Sendable {
        let homeserverURL: String
        let openIDToken: OpenIDTokenPayload
        let status: String
        
        init(filter: NitroReminderFilter, authentication: NitroReminderAuthentication) {
            homeserverURL = authentication.homeserverURL.absoluteString
            openIDToken = .init(token: authentication.openIDToken)
            status = filter.rawValue
        }
        
        private enum CodingKeys: String, CodingKey {
            case homeserverURL = "homeserver_url"
            case openIDToken = "openid_token"
            case status
        }
    }
    
    private struct ListResponse: Decodable, Sendable {
        let reminders: [NitroReminder]
        let nowTimestamp: Int
        
        private enum CodingKeys: String, CodingKey {
            case reminders
            case nowTimestamp = "now_ts"
        }
    }
    
    private struct ActionRequest: Encodable, Sendable {
        let homeserverURL: String
        let openIDToken: OpenIDTokenPayload
        let dueTimestamp: Int?
        
        init(authentication: NitroReminderAuthentication, dueDate: Date? = nil) {
            homeserverURL = authentication.homeserverURL.absoluteString
            openIDToken = .init(token: authentication.openIDToken)
            dueTimestamp = dueDate.map { Int($0.timeIntervalSince1970) }
        }
        
        private enum CodingKeys: String, CodingKey {
            case homeserverURL = "homeserver_url"
            case openIDToken = "openid_token"
            case dueTimestamp = "due_ts"
        }
    }
    
    private struct ActionResponse: Decodable, Sendable {
        let reminder: NitroReminder
    }
    
    private struct EmptyResponse: Decodable, Sendable { }
    
    private struct ErrorResponse: Decodable {
        let error: String
    }
    
    private let baseURL: URL
    private let urlSession: URLSession
    
    init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }
    
    func createReminder(_ schedule: NitroReminderSchedule,
                        authentication: NitroReminderAuthentication) async -> Result<NitroReminderCreation, NitroReminderError> {
        guard let request = CreateRequest(schedule: schedule, authentication: authentication) else {
            return .failure(.invalidResponse)
        }
        let result: Result<CreateResponse, NitroReminderError> = await post(path: "api/reminders",
                                                                            body: request)
        return result.map { .init(id: $0.id, dueDate: Date(timeIntervalSince1970: TimeInterval($0.dueTimestamp))) }
    }
    
    func reminders(filter: NitroReminderFilter,
                   authentication: NitroReminderAuthentication) async -> Result<NitroReminderList, NitroReminderError> {
        let result: Result<ListResponse, NitroReminderError> = await post(path: "api/reminders/list",
                                                                          body: ListRequest(filter: filter, authentication: authentication))
        return result.map { .init(reminders: $0.reminders, now: Date(timeIntervalSince1970: TimeInterval($0.nowTimestamp))) }
    }
    
    func markDone(reminderID: String,
                  authentication: NitroReminderAuthentication) async -> Result<NitroReminder, NitroReminderError> {
        let result: Result<ActionResponse, NitroReminderError> = await post(path: "api/reminders/\(reminderID)/done",
                                                                            body: ActionRequest(authentication: authentication))
        return result.map(\.reminder)
    }
    
    func snooze(reminderID: String,
                until dueDate: Date,
                authentication: NitroReminderAuthentication) async -> Result<NitroReminder, NitroReminderError> {
        let result: Result<ActionResponse, NitroReminderError> = await post(path: "api/reminders/\(reminderID)/snooze",
                                                                            body: ActionRequest(authentication: authentication, dueDate: dueDate))
        return result.map(\.reminder)
    }
    
    func deleteReminder(reminderID: String,
                        authentication: NitroReminderAuthentication) async -> Result<Void, NitroReminderError> {
        let result: Result<EmptyResponse, NitroReminderError> = await post(path: "api/reminders/\(reminderID)/delete",
                                                                           body: ActionRequest(authentication: authentication))
        return result.map { _ in () }
    }
    
    private func post<Request: Encodable & Sendable, Response: Decodable & Sendable>(path: String,
                                                                                     body: Request) async -> Result<Response, NitroReminderError> {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let data = try? JSONEncoder().encode(body) else {
            return .failure(.invalidResponse)
        }
        request.httpBody = data
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard (200..<300).contains(response.statusCode) else {
                let message = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
                return .failure(.httpError(statusCode: response.statusCode, message: message))
            }
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                return .failure(.invalidResponse)
            }
            return .success(response)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch {
            return .failure(.transport)
        }
    }
}
