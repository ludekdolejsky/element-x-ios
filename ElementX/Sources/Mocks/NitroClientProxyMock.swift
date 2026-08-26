//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

final class NitroClientProxyMock: NitroClientProxyProtocol {
    var homeserver: String
    var userID: String
    var nitroTaskService: NitroTaskServiceProtocol
    var nitroCatchUpService: NitroCatchUpServiceProtocol
    var requestOpenIDTokenReturnValue: Result<NitroOpenIDToken, ClientProxyError> = .failure(.invalidResponse)
    var requestOpenIDTokenClosure: (() async -> Result<NitroOpenIDToken, ClientProxyError>)?
    private(set) var requestOpenIDTokenCallsCount = 0
    
    init(homeserver: String = "",
         userID: String = "@alice:example.org",
         nitroTaskService: NitroTaskServiceProtocol = NitroTaskServiceMock(),
         nitroCatchUpService: NitroCatchUpServiceProtocol = NitroCatchUpServiceMock()) {
        self.homeserver = homeserver
        self.userID = userID
        self.nitroTaskService = nitroTaskService
        self.nitroCatchUpService = nitroCatchUpService
    }
    
    func requestOpenIDToken() async -> Result<NitroOpenIDToken, ClientProxyError> {
        requestOpenIDTokenCallsCount += 1
        return await requestOpenIDTokenClosure?() ?? requestOpenIDTokenReturnValue
    }
    
    func rawAccountData(eventType: String) async -> Result<String?, ClientProxyError> {
        .success(nil)
    }
    
    func setRawAccountData(eventType: String, content: String) async -> Result<Void, ClientProxyError> {
        .success(())
    }
    
    func emojiRoomStateEvents(roomID: String) async -> Result<[RoomStateEventProxy], ClientProxyError> {
        .success([])
    }
}
