//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct NitroTaskDetailsView: View {
    @Bindable var context: NitroTasksScreenViewModel.Context
    let taskID: String
    
    @State private var isEditing = false
    @State private var editedTitle = ""
    @State private var editedDescription = ""
    
    var body: some View {
        ElementNavigationStack {
            Form {
                if let task {
                    Section {
                        if isEditing {
                            TextField(UntranslatedL10n.screenNitroTaskTitleIos, text: $editedTitle)
                                .textInputAutocapitalization(.sentences)
                            TextField(UntranslatedL10n.screenNitroTaskDescriptionIos,
                                      text: $editedDescription,
                                      axis: .vertical)
                                .lineLimit(3...8)
                        } else {
                            Text(task.metadata.title)
                                .font(.compound.headingSMSemibold)
                                .foregroundStyle(.compound.textPrimary)
                            if let sourceText = task.sourceText {
                                Text(sourceText)
                                    .font(.compound.bodyMD)
                                    .foregroundStyle(.compound.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    
                    Section {
                        LabeledContent(UntranslatedL10n.screenNitroTaskRoomIos, value: task.roomName)
                        statusMenu(task)
                        assigneeMenu(task)
                        LabeledContent(UntranslatedL10n.screenNitroTaskCreatedIos,
                                       value: task.metadata.createdDate.formatted(date: .abbreviated, time: .shortened))
                        if let updatedDate = task.updatedDate {
                            LabeledContent(UntranslatedL10n.screenNitroTaskUpdatedIos,
                                           value: updatedDate.formatted(date: .abbreviated, time: .shortened))
                        }
                        if !task.stateIsAvailable {
                            Label(UntranslatedL10n.screenNitroTaskStateUnavailableIos, icon: \.warning)
                                .foregroundStyle(.compound.textCriticalPrimary)
                        }
                    }
                    
                    Section {
                        Button {
                            context.send(viewAction: .remind(task))
                        } label: {
                            Label(UntranslatedL10n.actionRemindMeIos, icon: \.notifications)
                        }
                        Button {
                            context.send(viewAction: .openTask(task))
                        } label: {
                            Label(UntranslatedL10n.actionOpenNitroTaskInRoomIos, icon: \.visibilityOn)
                        }
                        if task.metadata.sourceEventID != nil {
                            Button {
                                context.send(viewAction: .openSource(task))
                            } label: {
                                Label(UntranslatedL10n.actionOpenNitroTaskSourceIos, icon: \.link)
                            }
                        }
                        if task.canArchive {
                            Button(role: .destructive) {
                                context.send(viewAction: .archive(task))
                            } label: {
                                Label(UntranslatedL10n.actionArchiveNitroTaskIos, icon: \.delete)
                            }
                        }
                    }
                }
            }
            .compoundList()
            .disabled(isBusy)
            .navigationTitle(UntranslatedL10n.screenNitroTaskDetailsTitleIos)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditing {
                        Button(L10n.actionCancel) {
                            isEditing = false
                        }
                    } else if task?.canEditContent == true {
                        Button(L10n.actionEdit) {
                            beginEditing()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isBusy {
                        ProgressView()
                    } else if isEditing {
                        Button(L10n.actionSave) {
                            saveEdits()
                        }
                        .disabled(!canSave)
                    } else {
                        Button(L10n.actionDone) {
                            context.send(viewAction: .dismissDetails)
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: task?.metadata) { _, metadata in
            guard isEditing, let metadata else { return }
            let title = NitroTaskEventParser.normalizedTitle(editedTitle)
            let description = NitroTaskEventParser.normalizedDescription(editedDescription)
            if metadata.title == title, metadata.description == (description.isEmpty ? nil : description) {
                isEditing = false
            }
        }
    }
    
    private var task: NitroTask? {
        context.viewState.tasks.first { $0.id == taskID }
    }
    
    private var isBusy: Bool {
        context.viewState.busyTaskID == taskID
    }
    
    private var canSave: Bool {
        guard let task else { return false }
        let title = NitroTaskEventParser.normalizedTitle(editedTitle)
        let description = NitroTaskEventParser.normalizedDescription(editedDescription)
        return !title.isEmpty &&
            (title != task.metadata.title || task.metadata.description != (description.isEmpty ? nil : description))
    }
    
    private func beginEditing() {
        guard let task else { return }
        editedTitle = task.metadata.title
        editedDescription = task.metadata.description ?? ""
        isEditing = true
    }
    
    private func saveEdits() {
        guard let task, canSave else { return }
        context.send(viewAction: .editContent(title: editedTitle,
                                              description: editedDescription,
                                              task: task))
    }
    
    private func statusMenu(_ task: NitroTask) -> some View {
        Menu {
            ForEach(NitroTaskStatus.allCases) { status in
                Button(status.title) {
                    context.send(viewAction: .setStatus(status, task: task))
                }
            }
        } label: {
            LabeledContent(UntranslatedL10n.screenNitroTaskStatusIos, value: task.status.title)
        }
        .disabled(!task.canUpdate)
    }
    
    private func assigneeMenu(_ task: NitroTask) -> some View {
        Menu {
            Button(UntranslatedL10n.screenNitroTaskUnassignedIos) {
                context.send(viewAction: .setAssignee(nil, task: task))
            }
            ForEach(context.viewState.membersByRoomID[task.roomID] ?? []) { member in
                Button(member.title) {
                    context.send(viewAction: .setAssignee(member.id, task: task))
                }
            }
        } label: {
            LabeledContent(UntranslatedL10n.screenNitroTaskAssigneeIos,
                           value: task.assigneeDisplayName ?? task.state.assignee ?? UntranslatedL10n.screenNitroTaskUnassignedIos)
        }
        .disabled(!task.canUpdate)
    }
}

extension NitroTaskStatus {
    var title: String {
        switch self {
        case .todo: UntranslatedL10n.screenNitroTaskStatusTodoIos
        case .inProgress: UntranslatedL10n.screenNitroTaskStatusInProgressIos
        case .done: UntranslatedL10n.screenNitroTaskStatusDoneIos
        }
    }
}
