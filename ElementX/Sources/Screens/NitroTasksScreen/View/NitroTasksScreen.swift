//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct NitroTasksScreen: View {
    @Bindable var context: NitroTasksScreenViewModel.Context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        VStack(spacing: 0) {
            if context.viewState.hasLoaded {
                if context.viewState.isLoading {
                    refreshStatus
                } else if hasRecoveryStatus {
                    recoveryStatus
                }
            }
            
            Group {
                if context.viewState.isLoading, !context.viewState.hasLoaded {
                    ProgressView()
                } else if context.viewState.tasks.isEmpty {
                    emptyState
                } else if context.viewState.isFilteringBySearch, context.viewState.filteredTasks.isEmpty {
                    searchEmptyState
                } else if horizontalSizeClass == .regular {
                    board
                } else if context.viewState.isFilteringBySearch {
                    compactSearchResults
                } else {
                    compactList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.compound.bgCanvasDefault)
        .searchable(text: $context.searchQuery,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: UntranslatedL10n.screenNitroTasksSearchIos)
        .compoundSearchField()
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationTitle(UntranslatedL10n.screenNitroTasksTitleIos)
        .toolbar { toolbar }
        .alert(item: $context.alertInfo)
        .sheet(item: $context.selectedTask,
               onDismiss: { context.send(viewAction: .dismissDetails) },
               content: { task in
                   NitroTaskDetailsView(context: context, taskID: task.id)
               })
        .task {
            context.send(viewAction: .load)
        }
    }
    
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                context.send(viewAction: .showReminders)
            } label: {
                CompoundIcon(\.notifications)
            }
            .accessibilityLabel(UntranslatedL10n.screenNitroRemindersTitleIos)
            
            Button {
                context.send(viewAction: .showCreate)
            } label: {
                CompoundIcon(\.plus)
            }
            .accessibilityLabel(UntranslatedL10n.actionCreateNitroTaskIos)
        }
        
        if #available(iOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        
        ToolbarItem(placement: .primaryAction) {
            RoomFilterMenu(rooms: context.viewState.rooms,
                           selectedRoomID: context.selectedRoomID) { roomID in
                context.send(viewAction: .selectRoom(roomID))
            }
        }
    }
    
    private var compactList: some View {
        VStack(spacing: 0) {
            Picker(UntranslatedL10n.screenNitroTasksTitleIos, selection: $context.selectedStatus) {
                ForEach(NitroTaskStatus.allCases) { status in
                    Text(status.title).tag(status)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .onChange(of: context.selectedStatus) { _, status in
                context.send(viewAction: .selectStatus(status))
            }
            
            List {
                if hasUnavailableContent {
                    unavailableRow
                }
                let tasks = context.viewState.tasks(for: context.selectedStatus)
                if tasks.isEmpty {
                    compactEmptyRow
                } else {
                    ForEach(tasks) { task in
                        taskCard(task, useCardBackground: false)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                leadingSwipeAction(task)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                archiveSwipeAction(task)
                            }
                    }
                }
            }
            .compoundList()
            .refreshable {
                context.send(viewAction: .refresh)
            }
        }
    }
    
    private var compactSearchResults: some View {
        List {
            if hasUnavailableContent {
                unavailableRow
            }
            ForEach(NitroTaskStatus.allCases) { status in
                let tasks = context.viewState.tasks(for: status)
                if !tasks.isEmpty {
                    Section(status.title) {
                        ForEach(tasks) { task in
                            taskCard(task, useCardBackground: false)
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    leadingSwipeAction(task)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    archiveSwipeAction(task)
                                }
                        }
                    }
                }
            }
        }
        .compoundList()
        .refreshable {
            context.send(viewAction: .refresh)
        }
    }
    
    private var board: some View {
        VStack(spacing: 0) {
            if hasUnavailableContent {
                unavailableBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(NitroTaskStatus.allCases) { status in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(status.title)
                                .font(.compound.bodyMDSemibold)
                                .foregroundStyle(.compound.textPrimary)
                            Spacer()
                            Text(String(context.viewState.tasks(for: status).count))
                                .font(.compound.bodySM)
                                .foregroundStyle(.compound.textSecondary)
                        }
                        
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                let tasks = context.viewState.tasks(for: status)
                                if tasks.isEmpty {
                                    Text(UntranslatedL10n.screenNitroTasksColumnEmptyIos)
                                        .font(.compound.bodySM)
                                        .foregroundStyle(.compound.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8)
                                } else {
                                    ForEach(tasks) { task in
                                        taskCard(task, useCardBackground: true)
                                    }
                                }
                            }
                        }
                        .refreshable {
                            context.send(viewAction: .refresh)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(16)
        }
    }
    
    private func taskCard(_ task: NitroTask, useCardBackground: Bool) -> some View {
        NitroTaskCard(task: task,
                      isBusy: context.viewState.busyTaskID == task.id,
                      useCardBackground: useCardBackground) {
            context.send(viewAction: .selectTask(task))
        }
        .contextMenu {
            statusMenu(task)
            Button {
                context.send(viewAction: .openTask(task))
            } label: {
                Label(UntranslatedL10n.actionOpenNitroTaskInRoomIos, icon: \.visibilityOn)
            }
            Button {
                context.send(viewAction: .remind(task))
            } label: {
                Label(UntranslatedL10n.actionRemindMeIos, icon: \.notifications)
            }
            if task.canArchive {
                Button(role: .destructive) {
                    context.send(viewAction: .archive(task))
                } label: {
                    Label(UntranslatedL10n.actionArchiveNitroTaskIos, icon: \.delete)
                }
            }
        }
        .disabled(context.viewState.isMutating)
    }
    
    private func statusMenu(_ task: NitroTask) -> some View {
        Menu(UntranslatedL10n.screenNitroTaskStatusIos) {
            ForEach(NitroTaskStatus.allCases) { status in
                Button(status.title) {
                    context.send(viewAction: .setStatus(status, task: task))
                }
                if status == .inProgress {
                    Button(UntranslatedL10n.actionStartNitroTaskWithCodexIos) {
                        context.send(viewAction: .startWithCodex(task))
                    }
                }
            }
        }
        .disabled(!task.canUpdate)
    }
    
    @ViewBuilder
    private func leadingSwipeAction(_ task: NitroTask) -> some View {
        if task.canUpdate {
            switch task.status {
            case .todo:
                Button(UntranslatedL10n.actionStartNitroTaskIos) {
                    context.send(viewAction: .setStatus(.inProgress, task: task))
                }
                .tint(.compound.bgActionPrimaryRest)
            case .inProgress:
                Button(L10n.actionDone) {
                    context.send(viewAction: .setStatus(.done, task: task))
                }
                .tint(.compound.bgSuccessSubtle)
            case .done:
                Button(UntranslatedL10n.actionReopenNitroTaskIos) {
                    context.send(viewAction: .setStatus(.todo, task: task))
                }
                .tint(.compound.bgSubtleSecondary)
            }
        }
    }
    
    @ViewBuilder
    private func archiveSwipeAction(_ task: NitroTask) -> some View {
        if task.canArchive {
            Button(role: .destructive) {
                context.send(viewAction: .archive(task))
            } label: {
                Label(UntranslatedL10n.actionArchiveNitroTaskIos, icon: \.delete)
            }
        }
    }
    
    private var emptyState: some View {
        ZStack {
            VStack(spacing: 12) {
                CompoundIcon(\.checkCircle, size: .custom(48), relativeTo: .compound.headingLG)
                    .foregroundStyle(.compound.iconSecondary)
                Text(UntranslatedL10n.screenNitroTasksEmptyTitleIos)
                    .font(.compound.headingMDBold)
                    .foregroundStyle(.compound.textPrimary)
                Text(UntranslatedL10n.screenNitroTasksEmptyMessageIos)
                    .font(.compound.bodyMD)
                    .foregroundStyle(.compound.textSecondary)
                    .multilineTextAlignment(.center)
                Button(UntranslatedL10n.actionCreateNitroTaskIos) {
                    context.send(viewAction: .showCreate)
                }
                .buttonStyle(.compound(.primary, size: .medium))
                Button(UntranslatedL10n.actionRefreshIos) {
                    context.send(viewAction: .refresh)
                }
                .buttonStyle(.compound(.secondary, size: .medium))
            }
            .padding(24)
            
            if hasUnavailableContent {
                unavailableBanner
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
        }
    }
    
    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            CompoundIcon(\.search, size: .custom(48), relativeTo: .compound.headingLG)
                .foregroundStyle(.compound.iconSecondary)
            Text(L10n.commonNoResults)
                .font(.compound.headingMDBold)
                .foregroundStyle(.compound.textPrimary)
            Button(L10n.actionClear) {
                context.searchQuery = ""
            }
            .buttonStyle(.compound(.secondary, size: .medium))
        }
        .padding(24)
    }
    
    private var compactEmptyRow: some View {
        Text(UntranslatedL10n.screenNitroTasksColumnEmptyIos)
            .font(.compound.bodyMD)
            .foregroundStyle(.compound.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 32)
    }
    
    private var hasUnavailableContent: Bool {
        context.viewState.unavailableRoomCount > 0 || context.viewState.filteredTasks.contains { !$0.stateIsAvailable }
    }
    
    private var hasRecoveryStatus: Bool {
        context.viewState.pendingEventCount > 0 || context.viewState.failedEventCount > 0
    }
    
    private var refreshStatus: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.commonLoading)
                .font(.compound.bodySM)
                .foregroundStyle(.compound.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.compound.bgSubtleSecondary)
    }
    
    private var recoveryStatus: some View {
        HStack(spacing: 8) {
            if context.viewState.pendingEventCount > 0 {
                ProgressView()
                    .controlSize(.small)
                Text(UntranslatedL10n.screenNitroTasksLoadingOlderIos)
                    .font(.compound.bodySM)
                    .foregroundStyle(.compound.textSecondary)
            } else {
                CompoundIcon(\.warning, size: .xSmall, relativeTo: .compound.bodySM)
                    .foregroundStyle(.compound.iconCriticalPrimary)
                Text(UntranslatedL10n.screenNitroTasksLoadingOlderFailedIos)
                    .font(.compound.bodySM)
                    .foregroundStyle(.compound.textCriticalPrimary)
                Spacer()
                Button(L10n.actionTryAgain) {
                    context.send(viewAction: .retryPendingTasks)
                }
                .buttonStyle(.compound(.textLink, size: .small))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(context.viewState.pendingEventCount > 0 ? Color.compound.bgSubtleSecondary : .compound.bgCriticalSubtle)
    }
    
    private var unavailableRow: some View {
        unavailableBanner
            .listRowBackground(Color.compound.bgCriticalSubtle)
    }
    
    private var unavailableBanner: some View {
        Label(UntranslatedL10n.screenNitroTasksUnavailableMessageIos, icon: \.warning)
            .font(.compound.bodySM)
            .foregroundStyle(.compound.textCriticalPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.compound.bgCriticalSubtle, in: RoundedRectangle(cornerRadius: 8))
    }
    
    private struct RoomFilterMenu: View {
        @Environment(\.isInSidebar) private var isInSidebar
        
        let rooms: [NitroTaskRoom]
        let selectedRoomID: String?
        let action: (String?) -> Void
        
        var body: some View {
            if #available(iOS 26, *), !isInSidebar {
                if selectedRoomID != nil {
                    content
                        .backportButtonStyleGlassProminent()
                        .tint(.compound.bgActionPrimaryRest)
                } else {
                    content
                }
            } else if selectedRoomID != nil {
                content
                    .buttonStyle(.compound(.primary, size: .toolbarIcon))
            } else {
                content
                    .buttonStyle(.compound(.tertiary, size: .toolbarIcon))
            }
        }
        
        private var content: some View {
            Menu {
                filterButton(title: UntranslatedL10n.screenNitroTasksAllRoomsIos, roomID: nil)
                if !rooms.isEmpty {
                    Divider()
                }
                ForEach(rooms) { room in
                    filterButton(title: room.name, roomID: room.id)
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    CompoundIcon(\.filter)
                    if selectedRoomID != nil {
                        Circle()
                            .fill(Color.compound.iconAccentPrimary)
                            .frame(width: 8, height: 8)
                            .overlay {
                                Circle()
                                    .stroke(Color.compound.bgCanvasDefault, lineWidth: 1.5)
                            }
                            .offset(x: 3, y: -3)
                    }
                }
            }
            .disabled(rooms.isEmpty)
            .accessibilityLabel(UntranslatedL10n.screenNitroTasksFilterRoomIos)
            .accessibilityAddTraits(selectedRoomID == nil ? [] : .isSelected)
        }
        
        private func filterButton(title: String, roomID: String?) -> some View {
            Button {
                action(roomID)
            } label: {
                if selectedRoomID == roomID {
                    Label(title, icon: \.check)
                } else {
                    Text(title)
                }
            }
        }
    }
}

struct NitroTasksScreen_Previews: PreviewProvider, TestablePreview {
    static let viewModel: NitroTasksScreenViewModel = {
        let service = NitroTaskServiceMock()
        let task = NitroTask(id: "$task:example.org",
                             roomID: "!room:example.org",
                             roomName: "Nitro team",
                             metadata: .init(title: "Ship the iOS task board",
                                             description: "Review the adaptive layout and publish the next TestFlight build.",
                                             batchID: "preview",
                                             sourceRoomID: nil,
                                             sourceEventID: nil,
                                             sourceThreadRootID: nil,
                                             sourcePermalink: nil,
                                             initialState: .default,
                                             createdDate: .now),
                             state: .init(status: .todo, assignee: "@alice:example.org"),
                             stateIsAvailable: true,
                             assigneeDisplayName: "Alice",
                             updatedDate: .now,
                             canUpdate: true,
                             canArchive: true)
        service.loadTasksReturnValue = .success(.init(tasks: [task], unavailableRoomCount: 0))
        return NitroTasksScreenViewModel(taskService: service)
    }()
    
    static var previews: some View {
        ElementNavigationStack {
            NitroTasksScreen(context: viewModel.context)
        }
        .snapshotPreferences(expect: viewModel.context.observe(\.viewState.hasLoaded))
    }
}
