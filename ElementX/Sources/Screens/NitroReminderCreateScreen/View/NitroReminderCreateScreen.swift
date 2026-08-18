//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct NitroReminderCreateScreen: View {
    @Bindable var context: NitroReminderCreateScreenViewModel.Context
    
    var body: some View {
        ElementNavigationStack {
            Form {
                Section {
                    Text(UntranslatedL10n.screenNitroReminderCreateHintIos)
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textSecondary)
                }
                
                Section(UntranslatedL10n.screenNitroReminderCreateTimeHeaderIos) {
                    ForEach(NitroReminderCreatePreset.allCases) { preset in
                        Button {
                            context.selectedPreset = preset
                        } label: {
                            HStack(spacing: 12) {
                                Text(preset.title)
                                    .foregroundStyle(.compound.textPrimary)
                                Spacer()
                                if context.selectedPreset == preset {
                                    CompoundIcon(\.check)
                                        .foregroundStyle(.compound.iconAccentTertiary)
                                }
                            }
                        }
                        .disabled(context.viewState.isSaving)
                    }
                    
                    if context.selectedPreset == .custom {
                        DatePicker(UntranslatedL10n.screenNitroReminderCustomTimeIos,
                                   selection: $context.customDate,
                                   in: Date().addingTimeInterval(1)...)
                    }
                }
            }
            .compoundList()
            .navigationTitle(UntranslatedL10n.screenNitroReminderCreateTitleIos)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) {
                        context.send(viewAction: .cancel)
                    }
                    .disabled(context.viewState.isSaving)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(UntranslatedL10n.actionSetReminderIos) {
                        context.send(viewAction: .setReminder)
                    }
                    .disabled(context.viewState.isSaving)
                }
            }
            .overlay {
                if context.viewState.isSaving {
                    ProgressView()
                }
            }
            .alert(item: $context.alertInfo)
            .interactiveDismissDisabled(context.viewState.isSaving)
        }
    }
}

// MARK: - Previews

struct NitroReminderCreateScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel = NitroReminderCreateScreenViewModel(eventID: "$event:example.com",
                                                              threadRootID: nil,
                                                              roomProxy: JoinedRoomProxyMock(.init(name: "Nitro team")),
                                                              clientProxy: NitroClientProxyMock(homeserver: "https://example.com"),
                                                              reminderService: NitroReminderService(baseURL: .homeDirectory),
                                                              userIndicatorController: UserIndicatorControllerMock())
    
    static var previews: some View {
        NitroReminderCreateScreen(context: viewModel.context)
    }
}
