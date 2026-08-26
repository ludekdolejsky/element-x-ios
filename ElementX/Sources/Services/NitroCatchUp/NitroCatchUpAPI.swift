//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

protocol NitroCatchUpAPIProtocol {
    func start(requestID: String,
               roomID: String,
               roomName: String,
               mode: NitroCatchUpMode,
               messages: [NitroCatchUpMessage],
               authentication: NitroCatchUpAuthentication) async throws -> NitroCatchUpJob
    func poll(jobID: String, authentication: NitroCatchUpAuthentication) async throws -> NitroCatchUpJob
    func jobs(authentication: NitroCatchUpAuthentication) async throws -> [NitroCatchUpJob]
    func cancel(jobID: String,
                authentication: NitroCatchUpAuthentication,
                timeoutInterval: TimeInterval) async throws -> NitroCatchUpJob
    func dismiss(jobID: String, authentication: NitroCatchUpAuthentication) async throws
}

extension NitroCatchUpAPIProtocol {
    func cancel(jobID: String, authentication: NitroCatchUpAuthentication) async throws -> NitroCatchUpJob {
        try await cancel(jobID: jobID, authentication: authentication, timeoutInterval: 60)
    }
}

nonisolated enum NitroCatchUpAPIError: Error, Equatable, Sendable {
    case httpStatus(Int, message: String?)
}

nonisolated enum NitroCatchUpRequestLimits {
    static let maximumRequestByteCount = 4 * 1024 * 1024
    static let maximumMessagesByteCount = maximumRequestByteCount - 64 * 1024
}

nonisolated struct NitroCatchUpMessage: Encodable, Equatable, Sendable {
    let eventID: String
    let sender: String
    let senderID: String
    let timestamp: String
    let body: String
    let permalink: String
    let threadRootID: String?
    
    private enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case sender
        case senderID = "sender_id"
        case timestamp
        case body
        case permalink
        case threadRootID = "thread_root_id"
    }
}

nonisolated struct NitroCatchUpMessageBuffer {
    private(set) var messages = [NitroCatchUpMessage]()
    private var encodedByteCount = 2
    
    mutating func append(_ message: NitroCatchUpMessage) throws {
        let messageByteCount = try JSONEncoder().encode(message).count
        let separatorByteCount = messages.isEmpty ? 0 : 1
        guard encodedByteCount + separatorByteCount + messageByteCount <= NitroCatchUpRequestLimits.maximumMessagesByteCount else {
            throw NitroCatchUpServiceError.rangeTooLarge
        }
        encodedByteCount += separatorByteCount + messageByteCount
        messages.append(message)
    }
}

nonisolated struct NitroCatchUpJob: Decodable, Equatable, Sendable {
    let id: String
    let status: String
    let stage: String
    let completedSteps: Int
    let totalSteps: Int
    let messageCount: Int
    let elapsedSeconds: Int
    let summary: String?
    let error: String?
    let model: String?
    let promptVersion: String?
    let roomID: String?
    let roomName: String?
    let mode: NitroCatchUpMode?
    
    var isFinished: Bool {
        ["completed", "failed", "cancelled", "interrupted"].contains(status)
    }
    
    private enum CodingKeys: String, CodingKey {
        case id = "job_id"
        case status
        case stage
        case completedSteps = "completed_steps"
        case totalSteps = "total_steps"
        case messageCount = "message_count"
        case elapsedSeconds = "elapsed_sec"
        case summary
        case error
        case model
        case promptVersion = "prompt_version"
        case roomID = "room_id"
        case roomName = "room_name"
        case mode
    }
    
    init(id: String,
         status: String,
         stage: String? = nil,
         completedSteps: Int = 0,
         totalSteps: Int = 0,
         messageCount: Int = 0,
         elapsedSeconds: Int = 0,
         summary: String? = nil,
         error: String? = nil,
         model: String? = nil,
         promptVersion: String? = nil,
         roomID: String? = nil,
         roomName: String? = nil,
         mode: NitroCatchUpMode? = nil) {
        self.id = id
        self.status = status
        self.stage = stage ?? status
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.messageCount = messageCount
        self.elapsedSeconds = elapsedSeconds
        self.summary = summary
        self.error = error
        self.model = model
        self.promptVersion = promptVersion
        self.roomID = roomID
        self.roomName = roomName
        self.mode = mode
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        stage = try container.decodeIfPresent(String.self, forKey: .stage) ?? status
        completedSteps = try container.decodeIfPresent(Int.self, forKey: .completedSteps) ?? 0
        totalSteps = try container.decodeIfPresent(Int.self, forKey: .totalSteps) ?? 0
        messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        elapsedSeconds = try container.decodeIfPresent(Int.self, forKey: .elapsedSeconds) ?? 0
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        promptVersion = try container.decodeIfPresent(String.self, forKey: .promptVersion)
        roomID = try container.decodeIfPresent(String.self, forKey: .roomID)
        roomName = try container.decodeIfPresent(String.self, forKey: .roomName)
        mode = try container.decodeIfPresent(NitroCatchUpMode.self, forKey: .mode)
    }
}

nonisolated struct NitroCatchUpAuthentication: Sendable {
    let homeserverURL: String
    let openIDToken: NitroOpenIDToken
}

nonisolated struct NitroCatchUpAPI: Sendable {
    private struct OpenIDTokenPayload: Encodable, Sendable {
        let accessToken: String
        let tokenType: String
        let matrixServerName: String
        
        init(_ token: NitroOpenIDToken) {
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
    
    private struct StartRequest: Encodable, Sendable {
        let homeserverURL: String
        let openIDToken: OpenIDTokenPayload
        let requestID: String
        let roomID: String
        let roomName: String
        let mode: NitroCatchUpMode
        let messages: [NitroCatchUpMessage]
        
        private enum CodingKeys: String, CodingKey {
            case homeserverURL = "homeserver_url"
            case openIDToken = "openid_token"
            case requestID = "request_id"
            case roomID = "room_id"
            case roomName = "room_name"
            case mode
            case messages
        }
    }
    
    private struct AuthenticationRequest: Encodable, Sendable {
        let homeserverURL: String
        let openIDToken: OpenIDTokenPayload
        let jobID: String?
        
        init(authentication: NitroCatchUpAuthentication, jobID: String? = nil) {
            homeserverURL = authentication.homeserverURL
            openIDToken = .init(authentication.openIDToken)
            self.jobID = jobID
        }
        
        private enum CodingKeys: String, CodingKey {
            case homeserverURL = "homeserver_url"
            case openIDToken = "openid_token"
            case jobID = "job_id"
        }
    }
    
    private struct JobList: Decodable, Sendable {
        let jobs: [NitroCatchUpJob]
    }
    
    private let baseURL: URL
    private let urlSession: URLSession
    
    init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }
    
    func start(requestID: String,
               roomID: String,
               roomName: String,
               mode: NitroCatchUpMode,
               messages: [NitroCatchUpMessage],
               authentication: NitroCatchUpAuthentication) async throws -> NitroCatchUpJob {
        try await send(path: "api/catch-up/jobs",
                       method: "POST",
                       body: StartRequest(homeserverURL: authentication.homeserverURL,
                                          openIDToken: .init(authentication.openIDToken),
                                          requestID: requestID,
                                          roomID: roomID,
                                          roomName: roomName,
                                          mode: mode,
                                          messages: messages))
    }
    
    func poll(jobID: String, authentication: NitroCatchUpAuthentication) async throws -> NitroCatchUpJob {
        try await send(path: "api/catch-up/jobs/\(jobID)",
                       method: "POST",
                       body: AuthenticationRequest(authentication: authentication))
    }
    
    func jobs(authentication: NitroCatchUpAuthentication) async throws -> [NitroCatchUpJob] {
        let list: JobList = try await send(path: "api/catch-up/jobs/list",
                                           method: "POST",
                                           body: AuthenticationRequest(authentication: authentication))
        return list.jobs
    }
    
    func cancel(jobID: String,
                authentication: NitroCatchUpAuthentication,
                timeoutInterval: TimeInterval = 60) async throws -> NitroCatchUpJob {
        try await send(path: "api/catch-up/jobs/\(jobID)",
                       method: "DELETE",
                       body: AuthenticationRequest(authentication: authentication),
                       timeoutInterval: timeoutInterval)
    }
    
    func dismiss(jobID: String, authentication: NitroCatchUpAuthentication) async throws {
        let _: EmptyResponse = try await send(path: "api/catch-up/jobs/dismiss",
                                              method: "POST",
                                              body: AuthenticationRequest(authentication: authentication, jobID: jobID))
    }
    
    private struct EmptyResponse: Decodable, Sendable { }
    
    private struct ErrorResponse: Decodable, Sendable {
        let error: String
    }
    
    @concurrent private func send<Request: Encodable & Sendable, Response: Decodable & Sendable>(path: String,
                                                                                                 method: String,
                                                                                                 body: Request,
                                                                                                 timeoutInterval: TimeInterval = 60) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestBody = try JSONEncoder().encode(body)
        guard requestBody.count <= NitroCatchUpRequestLimits.maximumRequestByteCount else {
            throw NitroCatchUpServiceError.rangeTooLarge
        }
        request.httpBody = requestBody
        
        let (data, response) = try await urlSession.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw NitroCatchUpServiceError.invalidResponse
        }
        guard response.statusCode != 413 else {
            throw NitroCatchUpServiceError.rangeTooLarge
        }
        guard (200..<300).contains(response.statusCode) else {
            MXLog.error("Catch me up request failed with HTTP \(response.statusCode)")
            let message = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
            throw NitroCatchUpAPIError.httpStatus(response.statusCode, message: message)
        }
        guard !data.isEmpty else {
            if Response.self == EmptyResponse.self, let empty = EmptyResponse() as? Response {
                return empty
            }
            throw NitroCatchUpServiceError.invalidResponse
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

extension NitroCatchUpAPI: NitroCatchUpAPIProtocol { }

extension NitroCatchUpMode: Codable { }
