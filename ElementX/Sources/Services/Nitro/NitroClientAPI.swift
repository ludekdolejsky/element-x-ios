//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRustSDK

protocol NitroClientProxyProtocol: AnyObject {
    var homeserver: String { get }
    var userID: String { get }
    var nitroTaskService: NitroTaskServiceProtocol { get }
    func requestOpenIDToken() async -> Result<NitroOpenIDToken, ClientProxyError>
    func rawAccountData(eventType: String) async -> Result<String?, ClientProxyError>
    func setRawAccountData(eventType: String, content: String) async -> Result<Void, ClientProxyError>
    func emojiRoomStateEvents(roomID: String) async -> Result<[RoomStateEventProxy], ClientProxyError>
}

extension ClientProxy: NitroClientProxyProtocol { }

private actor NitroRoomStateEventsCache {
    private struct Entry {
        let events: [RoomStateEventProxy]
        let timestamp: Date
    }
    
    private let lifetime: TimeInterval = 5 * 60
    private let maximumEntryCount = 16
    private var entries = [String: Entry]()
    
    func events(for roomID: String) -> [RoomStateEventProxy]? {
        removeExpiredEntries()
        return entries[roomID]?.events
    }
    
    func store(_ events: [RoomStateEventProxy], for roomID: String) {
        removeExpiredEntries()
        if entries[roomID] == nil,
           entries.count >= maximumEntryCount,
           let oldestRoomID = entries.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
            entries[oldestRoomID] = nil
        }
        entries[roomID] = Entry(events: events, timestamp: Date())
    }
    
    private func removeExpiredEntries() {
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.timestamp) < lifetime }
    }
}

final class NitroClientAPI {
    private let client: ClientProtocol
    private let roomStateEventsCache = NitroRoomStateEventsCache()
    
    init(client: ClientProtocol) {
        self.client = client
    }
    
    func requestOpenIDToken() async -> Result<NitroOpenIDToken, ClientProxyError> {
        do {
            let token = try await client.requestOpenidToken()
            return .success(.init(accessToken: token.accessToken,
                                  tokenType: token.tokenType,
                                  matrixServerName: token.matrixServerName))
        } catch {
            MXLog.error("Failed requesting an OpenID token")
            return .failure(.sdkError(error))
        }
    }
    
    func rawAccountData(eventType: String) async -> Result<String?, ClientProxyError> {
        do {
            return try await .success(client.accountData(eventType: eventType))
        } catch {
            MXLog.error("Failed loading account data for \(eventType) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func setRawAccountData(eventType: String, content: String) async -> Result<Void, ClientProxyError> {
        do {
            try await client.setAccountData(eventType: eventType, content: content)
            return .success(())
        } catch {
            MXLog.error("Failed saving account data for \(eventType) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    func emojiRoomStateEvents(roomID: String) async -> Result<[RoomStateEventProxy], ClientProxyError> {
        if let cachedEvents = await roomStateEventsCache.events(for: roomID) {
            return .success(cachedEvents)
        }
        
        do {
            let session = try client.session()
            let ownUserID = try client.userId()
            guard let url = roomStateURL(homeserver: session.homeserverUrl, roomID: roomID) else {
                return .failure(.invalidResponse)
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            
            switch response.statusCode {
            case 200:
                let roomStateEvents = try await Self.decodeEmojiRoomStateEvents(data,
                                                                                roomID: roomID,
                                                                                ownUserID: ownUserID)
                await roomStateEventsCache.store(roomStateEvents, for: roomID)
                return .success(roomStateEvents)
            case 403:
                return .failure(.forbiddenAccess)
            case 404:
                return .success([])
            default:
                MXLog.error("Unexpected room state response \(response.statusCode) for \(roomID)")
                return .failure(.invalidResponse)
            }
        } catch let error as CancellationError {
            return .failure(.sdkError(error))
        } catch let error as ClientProxyError {
            return .failure(error)
        } catch {
            MXLog.error("Failed loading room state for \(roomID) with error: \(error)")
            return .failure(.sdkError(error))
        }
    }
    
    private func roomStateURL(homeserver: String, roomID: String) -> URL? {
        guard var components = URLComponents(string: homeserver) else {
            return nil
        }
        
        let pathSegmentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encodedRoomID = roomID.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) else {
            return nil
        }
        
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/_matrix/client/v3/rooms/\(encodedRoomID)/state"
        components.query = nil
        components.fragment = nil
        return components.url
    }
    
    @concurrent static func decodeEmojiRoomStateEvents(_ data: Data,
                                                       roomID: String,
                                                       ownUserID: String) async throws -> [RoomStateEventProxy] {
        try Task.checkCancellation()
        guard let events = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ClientProxyError.invalidResponse
        }
        
        return try events.compactMap { event in
            try Task.checkCancellation()
            guard let type = event["type"] as? String,
                  let stateKey = event["state_key"] as? String,
                  shouldKeepEmojiRoomStateEvent(type: type, stateKey: stateKey, ownUserID: ownUserID),
                  let content = event["content"] else {
                return nil
            }
            
            let contentData = try JSONSerialization.data(withJSONObject: content)
            guard let contentString = String(data: contentData, encoding: .utf8) else {
                throw ClientProxyError.invalidResponse
            }
            
            return RoomStateEventProxy(roomID: roomID,
                                       type: type,
                                       stateKey: stateKey,
                                       content: contentString)
        }
    }
    
    private nonisolated static func shouldKeepEmojiRoomStateEvent(type: String,
                                                                  stateKey: String,
                                                                  ownUserID: String) -> Bool {
        switch type {
        case "m.room.image_pack", "im.ponies.room_emotes", "m.room.name", "m.space.parent":
            true
        case "m.room.member":
            stateKey == ownUserID
        default:
            false
        }
    }
}
