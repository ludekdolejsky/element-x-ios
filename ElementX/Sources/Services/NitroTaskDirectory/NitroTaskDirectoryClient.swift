//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

nonisolated protocol NitroTaskDirectoryClientProtocol: Sendable {
    func resolve(_ keys: [NitroTaskDirectoryKey],
                 authentication: NitroTaskDirectoryAuthentication) async throws -> [NitroTaskDirectoryKey: NitroTaskDirectoryHint]
    func update(_ entries: [NitroTaskDirectoryUpdate],
                authentication: NitroTaskDirectoryAuthentication) async throws -> [NitroTaskDirectoryUpdateResult]
}

nonisolated struct NitroTaskDirectoryClient: NitroTaskDirectoryClientProtocol, Sendable {
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
    
    private struct ResolveRequest: Encodable, Sendable {
        let homeserverURL: String
        let openIDToken: OpenIDTokenPayload
        let tasks: [NitroTaskDirectoryKey]
        
        private enum CodingKeys: String, CodingKey {
            case homeserverURL = "homeserver_url"
            case openIDToken = "openid_token"
            case tasks
        }
    }
    
    private struct UpdateRequest: Encodable, Sendable {
        let homeserverURL: String
        let openIDToken: OpenIDTokenPayload
        let entries: [NitroTaskDirectoryUpdate]
        
        private enum CodingKeys: String, CodingKey {
            case homeserverURL = "homeserver_url"
            case openIDToken = "openid_token"
            case entries
        }
    }
    
    private struct ResolveResponse: Decodable, Sendable {
        let entries: [NitroTaskDirectoryHint]
    }
    
    private struct UpdateResponse: Decodable, Sendable {
        let entries: [NitroTaskDirectoryUpdateResult]
    }
    
    private static let maximumEntryCount = 5000
    private let baseURL: URL
    private let urlSession: URLSession
    
    init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }
    
    func resolve(_ keys: [NitroTaskDirectoryKey],
                 authentication: NitroTaskDirectoryAuthentication) async throws -> [NitroTaskDirectoryKey: NitroTaskDirectoryHint] {
        guard keys.count <= Self.maximumEntryCount, keys.allSatisfy(\.isValid) else {
            throw NitroTaskDirectoryError.invalidRequest
        }
        guard !keys.isEmpty else { return [:] }
        let response: ResolveResponse = try await send(path: "api/task-directory/resolve",
                                                       body: ResolveRequest(homeserverURL: authentication.homeserverURL,
                                                                            openIDToken: .init(authentication.openIDToken),
                                                                            tasks: keys))
        let requested = Set(keys)
        var result = [NitroTaskDirectoryKey: NitroTaskDirectoryHint]()
        for hint in response.entries where requested.contains(hint.key) {
            guard result[hint.key] == nil else { throw NitroTaskDirectoryError.invalidResponse }
            result[hint.key] = hint
        }
        return result
    }
    
    func update(_ entries: [NitroTaskDirectoryUpdate],
                authentication: NitroTaskDirectoryAuthentication) async throws -> [NitroTaskDirectoryUpdateResult] {
        guard !entries.isEmpty, entries.count <= Self.maximumEntryCount, entries.allSatisfy(\.isValid) else {
            throw NitroTaskDirectoryError.invalidRequest
        }
        let response: UpdateResponse = try await send(path: "api/task-directory/update",
                                                      body: UpdateRequest(homeserverURL: authentication.homeserverURL,
                                                                          openIDToken: .init(authentication.openIDToken),
                                                                          entries: entries))
        guard response.entries.count == entries.count,
              zip(response.entries, entries).allSatisfy({ pair in
                  pair.0.key == pair.1.key
              }) else {
            throw NitroTaskDirectoryError.invalidResponse
        }
        return response.entries
    }
    
    private func send<Request: Encodable & Sendable, Response: Decodable & Sendable>(path: String,
                                                                                     body: Request) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await urlSession.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw NitroTaskDirectoryError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw NitroTaskDirectoryError.httpStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw NitroTaskDirectoryError.invalidResponse
        }
    }
}
