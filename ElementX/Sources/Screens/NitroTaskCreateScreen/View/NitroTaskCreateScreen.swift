//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct NitroTaskCreateScreen: View {
    @Bindable var context: NitroTaskCreateScreenViewModel.Context
    
    var body: some View {
        ElementNavigationStack {
            Form {
                Section {
                    TextField(UntranslatedL10n.screenNitroTaskTitleIos,
                              text: $context.title,
                              axis: .vertical)
                        .lineLimit(1...4)
                    TextField(UntranslatedL10n.screenNitroTaskDescriptionIos,
                              text: $context.description,
                              axis: .vertical)
                        .lineLimit(3...10)
                }
                
                Section {
                    if context.viewState.fixedRoomID == nil {
                        Picker(UntranslatedL10n.screenNitroTaskRoomIos,
                               selection: selectedRoomBinding) {
                            ForEach(context.viewState.rooms) { room in
                                Text(room.name).tag(Optional(room.id))
                            }
                        }
                    } else {
                        LabeledContent(UntranslatedL10n.screenNitroTaskRoomIos,
                                       value: selectedRoomName)
                    }
                    
                    Picker(UntranslatedL10n.screenNitroTaskAssigneeIos,
                           selection: $context.selectedAssigneeID) {
                        Text(UntranslatedL10n.screenNitroTaskUnassignedIos).tag(String?.none)
                        ForEach(context.viewState.members) { member in
                            Text(member.title).tag(Optional(member.id))
                        }
                    }
                    .disabled(context.viewState.isLoadingMembers)
                }
            }
            .compoundList()
            .disabled(context.viewState.isSaving)
            .navigationTitle(UntranslatedL10n.screenNitroTaskCreateTitleIos)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) {
                        context.send(viewAction: .cancel)
                    }
                    .disabled(context.viewState.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if context.viewState.isSaving {
                        ProgressView()
                    } else {
                        Button(UntranslatedL10n.actionCreateNitroTaskIos) {
                            context.send(viewAction: .create)
                        }
                        .disabled(!context.viewState.canSubmit)
                    }
                }
            }
            .overlay {
                if context.viewState.isLoading, !context.viewState.hasLoaded {
                    ProgressView()
                }
            }
            .alert(item: $context.alertInfo)
            .interactiveDismissDisabled(context.viewState.isSaving)
            .task {
                context.send(viewAction: .load)
            }
        }
    }
    
    private var selectedRoomBinding: Binding<String?> {
        Binding(get: { context.selectedRoomID },
                set: { roomID in
                    if let roomID {
                        context.send(viewAction: .selectRoom(roomID))
                    }
                })
    }
    
    private var selectedRoomName: String {
        guard let roomID = context.selectedRoomID else { return "" }
        return context.viewState.rooms.first { $0.id == roomID }?.name ?? roomID
    }
}

struct NitroTaskCreateScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel: NitroTaskCreateScreenViewModel = {
        let service = NitroTaskServiceMock()
        service.loadRoomsReturnValue = .success([.init(id: "!nitro:example.org", name: "Nitro team")])
        service.loadMembersReturnValue = .success([.init(id: "@alice:example.org", displayName: "Alice", avatarURL: nil)])
        return NitroTaskCreateScreenViewModel(taskService: service,
                                              draft: .empty,
                                              userIndicatorController: UserIndicatorControllerMock())
    }()
    
    static var previews: some View {
        NitroTaskCreateScreen(context: viewModel.context)
            .snapshotPreferences(expect: viewModel.context.observe(\.viewState.hasLoaded))
    }
}
