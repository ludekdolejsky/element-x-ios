//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroTaskCreateScreenViewModelTests {
    @Test
    func loadsFixedRoomAndSuggestedAssignee() async throws {
        let service = NitroTaskServiceMock()
        service.loadRoomsReturnValue = .success([room])
        service.loadMembersReturnValue = .success([member])
        let viewModel = makeViewModel(service: service)
        let loadedMembers = deferFulfillment(viewModel.context.observe(\.viewState.members)) { $0 == [member] }
        
        viewModel.context.send(viewAction: .load)
        try await loadedMembers.fulfill()
        
        #expect(viewModel.context.selectedRoomID == room.id)
        #expect(viewModel.context.selectedAssigneeID == member.id)
        #expect(service.loadMembersReceivedRoomIDs == [room.id])
    }
    
    @Test
    func createsDesktopCompatibleRequestAndDismisses() async throws {
        let service = NitroTaskServiceMock()
        service.loadRoomsReturnValue = .success([room])
        service.loadMembersReturnValue = .success([member])
        let expectedTask = makeTask()
        service.createTaskReturnValue = .success(expectedTask)
        let indicatorController = UserIndicatorControllerMock()
        let viewModel = makeViewModel(service: service, indicatorController: indicatorController)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.members)) { $0 == [member] }
        viewModel.context.send(viewAction: .load)
        try await loaded.fulfill()
        let dismissed = deferFulfillment(viewModel.actionsPublisher) { action in
            guard case let .dismiss(createdTask) = action else { return false }
            return createdTask == expectedTask
        }
        
        viewModel.context.send(viewAction: .create)
        try await dismissed.fulfill()
        
        let request = try #require(service.createTaskReceivedRequests.first)
        #expect(request.roomID == room.id)
        #expect(request.title == "Ship the iOS board")
        #expect(request.description == "Keep it compatible with desktop.")
        #expect(request.assigneeID == member.id)
        #expect(request.origin?.eventID == "$source:example.org")
        #expect(indicatorController.submitIndicatorDelayCalled)
    }
    
    @Test
    func reportsUnavailableFixedRoom() async throws {
        let service = NitroTaskServiceMock()
        service.loadRoomsReturnValue = .success([])
        let viewModel = makeViewModel(service: service)
        let failed = deferFulfillment(viewModel.context.observe(\.viewState.bindings.alertInfo)) { $0?.id == .requestFailed }
        
        viewModel.context.send(viewAction: .load)
        try await failed.fulfill()
        
        #expect(viewModel.context.selectedRoomID == nil)
        #expect(!viewModel.context.viewState.canSubmit)
    }
    
    @Test
    func waitsForSuggestedAssigneeValidationBeforeCreating() async throws {
        let service = NitroTaskServiceMock()
        service.loadRoomsReturnValue = .success([room])
        let (memberResults, memberResultContinuation) = AsyncStream.makeStream(of: Result<[NitroTaskMember], NitroTaskServiceError>.self)
        service.loadMembersClosure = { _ in
            for await result in memberResults {
                return result
            }
            return .failure(.cancelled)
        }
        let viewModel = makeViewModel(service: service)
        let loadingMembers = deferFulfillment(viewModel.context.observe(\.viewState.isLoadingMembers)) { $0 }
        viewModel.context.send(viewAction: .load)
        try await loadingMembers.fulfill()
        
        #expect(!viewModel.context.viewState.canSubmit)
        let loadedMembers = deferFulfillment(viewModel.context.observe(\.viewState.members)) { $0 == [member] }
        memberResultContinuation.yield(.success([member]))
        memberResultContinuation.finish()
        try await loadedMembers.fulfill()
        #expect(viewModel.context.viewState.canSubmit)
    }
    
    @Test
    func clearsMembersWhenLoadingTheNewRoomFails() async throws {
        let otherRoom = NitroTaskRoom(id: "!other:example.org", name: "Other team")
        let service = NitroTaskServiceMock()
        service.loadRoomsReturnValue = .success([room, otherRoom])
        service.loadMembersClosure = { [room, member] roomID in
            roomID == room.id ? .success([member]) : .failure(.requestFailed)
        }
        let viewModel = makeSelectableViewModel(service: service)
        let loadedMembers = deferFulfillment(viewModel.context.observe(\.viewState.members)) { $0 == [member] }
        viewModel.context.send(viewAction: .load)
        try await loadedMembers.fulfill()
        let failed = deferFulfillment(viewModel.context.observe(\.viewState.bindings.alertInfo)) { $0?.id == .requestFailed }
        
        viewModel.context.send(viewAction: .selectRoom(otherRoom.id))
        try await failed.fulfill()
        
        #expect(viewModel.context.viewState.members.isEmpty)
        #expect(viewModel.context.selectedAssigneeID == nil)
    }
    
    private let room = NitroTaskRoom(id: "!nitro:example.org", name: "Nitro team")
    private let member = NitroTaskMember(id: "@bob:example.org", displayName: "Bob", avatarURL: nil)
    
    private func makeViewModel(service: NitroTaskServiceMock,
                               indicatorController: UserIndicatorControllerMock = .init()) -> NitroTaskCreateScreenViewModel {
        NitroTaskCreateScreenViewModel(taskService: service,
                                       draft: .init(title: "Ship the iOS board",
                                                    description: "Keep it compatible with desktop.",
                                                    fixedRoomID: room.id,
                                                    initialRoomID: nil,
                                                    suggestedAssigneeID: member.id,
                                                    origin: .init(roomID: room.id,
                                                                  eventID: "$source:example.org",
                                                                  threadRootID: nil,
                                                                  permalink: "https://matrix.to/#/!nitro:example.org/$source:example.org")),
                                       userIndicatorController: indicatorController)
    }
    
    private func makeSelectableViewModel(service: NitroTaskServiceMock) -> NitroTaskCreateScreenViewModel {
        NitroTaskCreateScreenViewModel(taskService: service,
                                       draft: .init(title: "Ship the iOS board",
                                                    description: "Keep it compatible with desktop.",
                                                    fixedRoomID: nil,
                                                    initialRoomID: nil,
                                                    suggestedAssigneeID: nil,
                                                    origin: nil),
                                       userIndicatorController: UserIndicatorControllerMock())
    }
    
    private func makeTask() -> NitroTask {
        .init(id: "$task:example.org",
              roomID: room.id,
              roomName: room.name,
              metadata: .init(title: "Ship the iOS board",
                              description: "Keep it compatible with desktop.",
                              batchID: "batch-1",
                              sourceRoomID: room.id,
                              sourceEventID: "$source:example.org",
                              sourceThreadRootID: nil,
                              sourcePermalink: nil,
                              initialState: .init(status: .todo, assignee: member.id),
                              createdDate: Date(timeIntervalSince1970: 1_800_000_000)),
              state: .init(status: .todo, assignee: member.id),
              stateIsAvailable: true,
              assigneeDisplayName: member.displayName,
              updatedDate: nil,
              canUpdate: true,
              canArchive: true)
    }
}
