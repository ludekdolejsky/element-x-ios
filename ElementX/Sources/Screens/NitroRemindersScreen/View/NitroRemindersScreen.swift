//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SFSafeSymbols
import SwiftUI

struct NitroRemindersScreen: View {
    @Bindable var context: NitroRemindersScreenViewModel.Context
    
    var body: some View {
        VStack(spacing: 0) {
            Picker(UntranslatedL10n.screenNitroRemindersTitleIos, selection: $context.filter) {
                ForEach(NitroReminderFilter.allCases, id: \.self) { filter in
                    Text(title(for: filter)).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .onChange(of: context.filter) { _, filter in
                context.send(viewAction: .selectFilter(filter))
            }
            
            content
        }
        .background(Color.compound.bgCanvasDefault)
        .navigationTitle(UntranslatedL10n.screenNitroRemindersTitleIos)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    context.send(viewAction: .refresh)
                } label: {
                    CompoundIcon(\.restart)
                }
                .disabled(context.viewState.isLoading)
                .accessibilityLabel(UntranslatedL10n.actionRefreshIos)
            }
        }
        .alert(item: $context.alertInfo)
        .sheet(item: $context.editingReminder) { reminder in
            editSheet(reminder: reminder)
        }
        .task {
            context.send(viewAction: .load)
        }
    }
    
    @ViewBuilder
    private var content: some View {
        if context.viewState.isLoading, !context.viewState.hasLoaded {
            Spacer()
            ProgressView()
            Spacer()
        } else if context.viewState.reminders.isEmpty {
            Spacer()
            emptyState
            Spacer()
        } else {
            List(context.viewState.reminders) { reminder in
                reminderRow(reminder)
            }
            .compoundList()
            .refreshable {
                context.send(viewAction: .refresh)
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            CompoundIcon(\.notificationsOffSolid, size: .custom(48), relativeTo: .compound.headingLG)
                .foregroundStyle(.compound.iconSecondary)
            Text(emptyTitle)
                .font(.compound.headingMDBold)
                .foregroundStyle(.compound.textPrimary)
            Text(emptyMessage)
                .font(.compound.bodyMD)
                .foregroundStyle(.compound.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
    
    private func reminderRow(_ reminder: NitroReminder) -> some View {
        let presentation = NitroReminderRowPresentation(reminder: reminder, serverNow: context.viewState.serverNow)
        return HStack(spacing: 12) {
            Button {
                context.send(viewAction: .open(reminder))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(reminder.roomName ?? reminder.roomID)
                            .font(.compound.bodySMSemibold)
                            .foregroundStyle(.compound.textPrimary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let badge = presentation.badge {
                            Text(badge)
                                .font(.compound.bodyXS)
                                .foregroundStyle(.compound.textOnSolidPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.compound.bgActionPrimaryRest, in: Capsule())
                        }
                        Spacer()
                        Text(presentation.status)
                            .font(.compound.bodyXS)
                            .foregroundStyle(.compound.textSecondary)
                    }
                    reminderPreview(reminder, presentation: presentation)
                    if let recurrence = presentation.recurrence {
                        Text(recurrence)
                            .font(.compound.bodyXS)
                            .foregroundStyle(.compound.textSecondary)
                            .lineLimit(1)
                    }
                    Text(UntranslatedL10n.screenNitroRemindersMetaIos(formatted(reminder.createdDate), formatted(reminder.dueDate)))
                        .font(.compound.bodyXS)
                        .foregroundStyle(.compound.textSecondary)
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if context.viewState.busyReminderID == reminder.id {
                ProgressView()
            } else {
                reminderMenu(reminder, presentation: presentation)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if context.viewState.busyReminderID != reminder.id {
                reminderMenuContent(reminder, presentation: presentation)
            }
        }
    }
    
    @ViewBuilder
    private func reminderPreview(_ reminder: NitroReminder, presentation: NitroReminderRowPresentation) -> some View {
        if let prompt = presentation.prompt {
            Text(prompt)
                .font(.compound.bodyMD)
                .foregroundStyle(.compound.textPrimary)
                .lineLimit(3)
        } else if let preview = context.viewState.previews[reminder.id] {
            Text(preview.text)
                .font(.compound.bodyMD)
                .foregroundStyle(preview.isAvailable ? .compound.textPrimary : .compound.textSecondary)
                .lineLimit(2)
            if let sender = preview.sender {
                HStack(spacing: 4) {
                    Text(sender)
                    if preview.isEdited {
                        Text("·")
                        Text(L10n.commonEditedSuffix)
                    }
                }
                .font(.compound.bodyXS)
                .foregroundStyle(.compound.textSecondary)
                .lineLimit(1)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(UntranslatedL10n.screenNitroRemindersLoadingMessageIos)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
            }
        }
    }
    
    private func reminderMenu(_ reminder: NitroReminder, presentation: NitroReminderRowPresentation) -> some View {
        Menu {
            reminderMenuContent(reminder, presentation: presentation)
        } label: {
            Image(systemSymbol: .ellipsis)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .foregroundStyle(.compound.iconPrimary)
        }
        .accessibilityLabel(L10n.actionOpenContextMenu)
    }
    
    @ViewBuilder
    private func reminderMenuContent(_ reminder: NitroReminder, presentation: NitroReminderRowPresentation) -> some View {
        Button {
            context.send(viewAction: .open(reminder))
        } label: {
            Label(presentation.openAction, icon: \.visibilityOn)
        }
        
        if reminder.status != .done {
            Button {
                context.send(viewAction: .markDone(reminder))
            } label: {
                Label(L10n.actionDone, icon: \.check)
            }
        }
        
        Section {
            Button(UntranslatedL10n.actionSnooze20MinutesIos) {
                context.send(viewAction: .snooze(reminder, 20 * 60))
            }
            Button(UntranslatedL10n.actionSnooze24HoursIos) {
                context.send(viewAction: .snooze(reminder, 24 * 60 * 60))
            }
            Button(UntranslatedL10n.actionSnoozeOneWeekIos) {
                context.send(viewAction: .snooze(reminder, 7 * 24 * 60 * 60))
            }
            Button {
                context.send(viewAction: .edit(reminder))
            } label: {
                Label(UntranslatedL10n.actionEditTimeIos, icon: \.edit)
            }
        }
        
        Button(role: .destructive) {
            context.send(viewAction: .delete(reminder))
        } label: {
            Label(L10n.actionDelete, icon: \.delete)
        }
    }
    
    private func editSheet(reminder: NitroReminder) -> some View {
        let isSaving = context.viewState.busyReminderID == reminder.id
        return ElementNavigationStack {
            Form {
                Section {
                    Text(UntranslatedL10n.screenNitroRemindersEditHintIos)
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textSecondary)
                    DatePicker(UntranslatedL10n.screenNitroReminderCustomTimeIos,
                               selection: $context.editDate,
                               in: Date().addingTimeInterval(1)...)
                }
            }
            .compoundList()
            .disabled(isSaving)
            .navigationTitle(UntranslatedL10n.screenNitroRemindersEditTitleIos)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) {
                        context.send(viewAction: .cancelEdit)
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(L10n.actionSave) {
                            context.send(viewAction: .saveEditedTime(reminderID: reminder.id))
                        }
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }
    
    private func title(for filter: NitroReminderFilter) -> String {
        switch filter {
        case .due: UntranslatedL10n.screenNitroRemindersDueIos
        case .upcoming: UntranslatedL10n.screenNitroRemindersUpcomingIos
        case .done: UntranslatedL10n.screenNitroRemindersDoneIos
        }
    }
    
    private var emptyTitle: String {
        switch context.filter {
        case .due: UntranslatedL10n.screenNitroRemindersEmptyDueTitleIos
        case .upcoming: UntranslatedL10n.screenNitroRemindersEmptyUpcomingTitleIos
        case .done: UntranslatedL10n.screenNitroRemindersEmptyDoneTitleIos
        }
    }
    
    private var emptyMessage: String {
        switch context.filter {
        case .due: UntranslatedL10n.screenNitroRemindersEmptyDueMessageIos
        case .upcoming: UntranslatedL10n.screenNitroRemindersEmptyUpcomingMessageIos
        case .done: UntranslatedL10n.screenNitroRemindersEmptyDoneMessageIos
        }
    }
    
    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Previews

struct NitroRemindersScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel: NitroRemindersScreenViewModel = {
        let clientProxy = NitroClientProxyMock(homeserver: "https://example.com")
        clientProxy.requestOpenIDTokenReturnValue = .failure(.invalidResponse)
        return NitroRemindersScreenViewModel(clientProxy: clientProxy,
                                             reminderService: NitroReminderService(baseURL: .homeDirectory),
                                             previewService: NitroReminderPreviewServiceMock())
    }()
    
    static var previews: some View {
        ElementNavigationStack {
            NitroRemindersScreen(context: viewModel.context)
        }
    }
}
