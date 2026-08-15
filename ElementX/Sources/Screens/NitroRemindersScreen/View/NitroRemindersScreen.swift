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
        HStack(spacing: 12) {
            Button {
                context.send(viewAction: .open(reminder))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(reminder.roomName ?? reminder.roomID)
                            .font(.compound.bodySMSemibold)
                            .foregroundStyle(.compound.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(status(for: reminder))
                            .font(.compound.bodyXS)
                            .foregroundStyle(.compound.textSecondary)
                    }
                    Text(UntranslatedL10n.screenNitroRemindersReminderLabelIos(reminder.label))
                        .font(.compound.bodyMD)
                        .foregroundStyle(.compound.textPrimary)
                        .lineLimit(2)
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
                reminderMenu(reminder)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func reminderMenu(_ reminder: NitroReminder) -> some View {
        Menu {
            Button {
                context.send(viewAction: .open(reminder))
            } label: {
                Label(UntranslatedL10n.actionOpenIos, icon: \.visibilityOn)
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
        } label: {
            Image(systemSymbol: .ellipsis)
                .foregroundStyle(.compound.iconPrimary)
        }
        .accessibilityLabel(L10n.actionOpenContextMenu)
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
    
    private func status(for reminder: NitroReminder) -> String {
        if reminder.status == .done {
            return UntranslatedL10n.screenNitroRemindersDoneIos
        }
        if reminder.dueDate <= context.viewState.serverNow {
            return UntranslatedL10n.screenNitroRemindersDueNowIos
        }
        return UntranslatedL10n.screenNitroRemindersUpcomingIos
    }
    
    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Previews

struct NitroRemindersScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel: NitroRemindersScreenViewModel = {
        let clientProxy = ClientProxyMock(.init(homeserver: "https://example.com"))
        clientProxy.requestOpenIDTokenReturnValue = .failure(.invalidResponse)
        return NitroRemindersScreenViewModel(clientProxy: clientProxy,
                                             reminderService: NitroReminderService(baseURL: .homeDirectory))
    }()
    
    static var previews: some View {
        ElementNavigationStack {
            NitroRemindersScreen(context: viewModel.context)
        }
    }
}
