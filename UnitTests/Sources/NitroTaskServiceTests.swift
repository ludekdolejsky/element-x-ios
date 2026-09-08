//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

struct NitroTaskServiceTests {
    @Test
    func unchangedTaskIndexIsNotWrittenDuringRefresh() async throws {
        let client = ClientSDKMock(.init())
        client.sessionReturnValue = .init(accessToken: "token",
                                          refreshToken: nil,
                                          userId: "@user:example.org",
                                          deviceId: "DEVICE",
                                          homeserverUrl: "https://example.org",
                                          oauthData: nil,
                                          slidingSyncVersion: .native)
        client.userIdReturnValue = "@user:example.org"
        client.roomsReturnValue = []
        client.accountDataEventTypeReturnValue = try NitroTaskIndex(migrationComplete: true,
                                                                    tasks: [],
                                                                    roomPinRevisions: [:]).jsonString()
        let service = NitroTaskService(client: client)
        
        guard case .success = await service.loadTasks() else {
            Issue.record("The task refresh unexpectedly failed.")
            return
        }
        
        #expect(client.setAccountDataEventTypeContentCallsCount == 0)
    }
    
    @Test
    func taskIndexRevisionIsStableAcrossEquivalentJSON() async {
        let client = ClientSDKMock(.init())
        let responses = NitroTaskAccountDataResponses(values: [
            """
            {"version":1,"migration_complete":true,"tasks":[{"room_id":"!one:example.org","event_id":"$one"},{"room_id":"!two:example.org","event_id":"$two"}],"room_pin_revisions":{}}
            """,
            """
            {"room_pin_revisions":{},"tasks":[{"event_id":"$two","room_id":"!two:example.org"},{"event_id":"$one","room_id":"!one:example.org"}],"migration_complete":true,"version":1}
            """
        ])
        client.accountDataEventTypeClosure = { _ in await responses.next() }
        let service = NitroTaskService(client: client)
        
        let firstRevision = await service.currentTaskIndexRevision()
        let secondRevision = await service.currentTaskIndexRevision()
        
        #expect(firstRevision != nil)
        #expect(firstRevision == secondRevision)
    }
    
    @Test
    func newerLoadWinsWhenCancelledIndexReadFinishesLater() async {
        let gate = NitroTaskAccountDataGate(blockedCalls: [1, 3])
        let client = ClientSDKMock(.init())
        client.sessionReturnValue = .init(accessToken: "token",
                                          refreshToken: nil,
                                          userId: "@user:example.org",
                                          deviceId: "DEVICE",
                                          homeserverUrl: "https://example.org",
                                          oauthData: nil,
                                          slidingSyncVersion: .native)
        client.userIdReturnValue = "@user:example.org"
        client.roomsReturnValue = []
        client.accountDataEventTypeClosure = { _ in await gate.response() }
        let service = NitroTaskService(client: client)
        
        let cancelledLoad = Task { await service.loadTasks() }
        await gate.waitUntilCall(1)
        cancelledLoad.cancel()
        
        let currentLoad = Task { await service.loadTasks() }
        await gate.waitUntilCall(3)
        await gate.release(call: 1)
        let cancelledResult = await cancelledLoad.value
        await gate.release(call: 3)
        let currentResult = await currentLoad.value
        
        guard case .failure(.cancelled) = cancelledResult else {
            Issue.record("The cancelled load unexpectedly completed.")
            return
        }
        guard case .success = currentResult else {
            Issue.record("The newer load was superseded by cancelled work.")
            return
        }
    }
}

private actor NitroTaskAccountDataResponses {
    private var values: [String]
    
    init(values: [String]) {
        self.values = values
    }
    
    func next() -> String? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private actor NitroTaskAccountDataGate {
    private let blockedCalls: Set<Int>
    private var callCount = 0
    private var responseContinuations = [Int: CheckedContinuation<String?, Never>]()
    private var callWaiters = [Int: [CheckedContinuation<Void, Never>]]()
    
    init(blockedCalls: Set<Int>) {
        self.blockedCalls = blockedCalls
    }
    
    func response() async -> String? {
        callCount += 1
        let call = callCount
        let readyWaiters = callWaiters.keys.filter { $0 <= call }
        for expectedCall in readyWaiters {
            callWaiters.removeValue(forKey: expectedCall)?.forEach { $0.resume() }
        }
        guard blockedCalls.contains(call) else { return nil }
        return await withCheckedContinuation { responseContinuations[call] = $0 }
    }
    
    func waitUntilCall(_ expectedCall: Int) async {
        guard callCount < expectedCall else { return }
        await withCheckedContinuation { callWaiters[expectedCall, default: []].append($0) }
    }
    
    func release(call: Int) {
        responseContinuations.removeValue(forKey: call)?.resume(returning: nil)
    }
}
