//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI

struct NitroCatchUpScreen: View {
    @Bindable var context: NitroCatchUpScreenViewModel.Context
    
    var body: some View {
        ElementNavigationStack {
            Group {
                if let operation = context.viewState.operation {
                    operationView(operation)
                } else {
                    form
                }
            }
            .navigationTitle(UntranslatedL10n.screenNitroCatchUpTitleIos)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionClose) {
                        context.send(viewAction: .close)
                    }
                }
            }
            .alert(item: $context.alertInfo)
        }
    }
    
    private var form: some View {
        Form {
            Section {
                Text(UntranslatedL10n.screenNitroCatchUpHintIos(context.viewState.roomName))
                    .foregroundStyle(.compound.textSecondary)
            }
            Section(UntranslatedL10n.screenNitroCatchUpFromIos) {
                Picker(UntranslatedL10n.screenNitroCatchUpFromIos, selection: $context.startPoint) {
                    Text(UntranslatedL10n.screenNitroCatchUpLastReadIos).tag(NitroCatchUpStartPoint.lastRead)
                    Text(UntranslatedL10n.screenNitroCatchUpDateIos).tag(NitroCatchUpStartPoint.date)
                }
                .pickerStyle(.inline)
                if context.startPoint == .date {
                    DatePicker(UntranslatedL10n.screenNitroCatchUpDateIos,
                               selection: $context.date,
                               in: ...Date())
                }
            }
            Section(UntranslatedL10n.screenNitroCatchUpShowMeIos) {
                Picker(UntranslatedL10n.screenNitroCatchUpShowMeIos, selection: $context.mode) {
                    Text(UntranslatedL10n.screenNitroCatchUpOverviewIos).tag(NitroCatchUpMode.overview)
                    Text(UntranslatedL10n.screenNitroCatchUpAttentionIos).tag(NitroCatchUpMode.attention)
                }
                .pickerStyle(.inline)
            }
            Section {
                Button(UntranslatedL10n.actionNitroCatchUpIos) {
                    context.send(viewAction: .start)
                }
                .buttonStyle(.compound(.primary, size: .medium))
                .frame(maxWidth: .infinity)
            } footer: {
                Text(UntranslatedL10n.screenNitroCatchUpBackgroundHintIos)
            }
        }
        .compoundList()
    }
    
    @ViewBuilder
    private func operationView(_ operation: NitroCatchUpOperation) -> some View {
        switch operation.state {
        case .completed(let result):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NitroCatchUpSummaryView(markdown: result.summary)
                        .textSelection(.enabled)
                    Text(UntranslatedL10n.screenNitroCatchUpMessageCountIos(result.messageCount))
                        .font(.compound.bodySM)
                        .foregroundStyle(.compound.textSecondary)
                    Button(L10n.actionDone) {
                        context.send(viewAction: .dismissResult)
                    }
                    .buttonStyle(.compound(.primary, size: .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        case .failed(let error):
            ContentUnavailableView(UntranslatedL10n.screenNitroCatchUpFailedIos,
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error.title))
                .safeAreaInset(edge: .bottom) {
                    Button(L10n.actionDone) {
                        context.send(viewAction: .dismissResult)
                    }
                    .buttonStyle(.compound(.primary, size: .medium))
                    .padding(16)
                }
        case .cancelled:
            ContentUnavailableView(UntranslatedL10n.screenNitroCatchUpCancelledIos, systemImage: "xmark.circle")
                .safeAreaInset(edge: .bottom) {
                    Button(L10n.actionDone) {
                        context.send(viewAction: .dismissResult)
                    }
                    .buttonStyle(.compound(.primary, size: .medium))
                    .padding(16)
                }
        case .reading(let progress):
            progressView(title: UntranslatedL10n.screenNitroCatchUpReadingIos,
                         detail: UntranslatedL10n.screenNitroCatchUpEventsScannedIos(progress.scannedEventCount))
        case .queued(let messageCount):
            progressView(title: UntranslatedL10n.screenNitroCatchUpQueuedIos,
                         detail: UntranslatedL10n.screenNitroCatchUpMessageCountIos(messageCount))
        case .running(let stage, let completedSteps, let totalSteps, let messageCount):
            let detail = totalSteps > 0
                ? UntranslatedL10n.screenNitroCatchUpProgressIos(completedSteps, totalSteps, messageCount)
                : UntranslatedL10n.screenNitroCatchUpMessageCountIos(messageCount)
            let title = switch stage {
            case "cancelling": UntranslatedL10n.screenNitroCatchUpCancellingIos
            case "merging": UntranslatedL10n.screenNitroCatchUpMergingIos
            default: UntranslatedL10n.screenNitroCatchUpSummarizingIos
            }
            progressView(title: title, detail: detail, showsCancelButton: stage != "cancelling")
        }
    }
    
    private func progressView(title: String, detail: String, showsCancelButton: Bool = true) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.compound.headingMDBold)
            Text(detail)
                .font(.compound.bodyMD)
                .foregroundStyle(.compound.textSecondary)
            Text(UntranslatedL10n.screenNitroCatchUpBackgroundHintIos)
                .font(.compound.bodySM)
                .foregroundStyle(.compound.textSecondary)
                .multilineTextAlignment(.center)
            if showsCancelButton {
                Button(L10n.actionCancel) {
                    context.send(viewAction: .cancel)
                }
                .buttonStyle(.compound(.secondary, size: .medium))
            }
        }
        .padding(24)
    }
}

private struct NitroCatchUpSummaryView: View {
    private let attributedString: AttributedString
    
    init(markdown: String) {
        let displayMarkdown = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(Self.normalizeBlockPrefix)
            .joined(separator: "\n")
        attributedString = (try? AttributedString(markdown: displayMarkdown,
                                                  options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(displayMarkdown)
    }
    
    var body: some View {
        Text(attributedString)
            .foregroundStyle(.compound.textPrimary)
            .tint(.compound.textLinkExternal)
    }
    
    private static func normalizeBlockPrefix(_ line: Substring) -> String {
        let contentStart = line.firstIndex { !$0.isWhitespace } ?? line.endIndex
        let indentation = line[..<contentStart]
        let content = line[contentStart...]
        
        if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ") {
            return "\(indentation)• \(content.dropFirst(2))"
        }
        
        let headingMarker = content.prefix { $0 == "#" }
        if !headingMarker.isEmpty,
           headingMarker.count <= 6,
           content.dropFirst(headingMarker.count).hasPrefix(" ") {
            return "\(indentation)**\(content.dropFirst(headingMarker.count + 1))**"
        }
        
        return String(line)
    }
}

private extension NitroCatchUpServiceError {
    var title: String {
        switch self {
        case .alreadyRunning:
            UntranslatedL10n.errorNitroCatchUpAlreadyRunningIos
        case .backend(let message):
            message
        case .noReadMarker:
            UntranslatedL10n.errorNitroCatchUpNoReadMarkerIos
        case .rangeTooLarge:
            UntranslatedL10n.errorNitroCatchUpRangeTooLargeIos
        case .roomUnavailable:
            UntranslatedL10n.errorNitroCatchUpRoomUnavailableIos
        case .invalidResponse, .transport:
            UntranslatedL10n.errorNitroCatchUpRequestFailedIos
        }
    }
}

// MARK: - Previews

struct NitroCatchUpScreen_Previews: PreviewProvider, TestablePreview {
    static let formViewModel = makeViewModel()
    static let runningViewModel = makeViewModel(state: .running(stage: "summarizing",
                                                                completedSteps: 2,
                                                                totalSteps: 5,
                                                                messageCount: 42))
    static let completedViewModel = makeViewModel(state: .completed(.init(summary: "## Highlights\n\n- A decision with a [source](https://matrix.to).",
                                                                          messageCount: 42,
                                                                          model: "Nitro",
                                                                          promptVersion: "preview")))
    
    static var previews: some View {
        NitroCatchUpScreen(context: formViewModel.context)
            .previewDisplayName("Form")
        NitroCatchUpScreen(context: runningViewModel.context)
            .previewDisplayName("Running")
        NitroCatchUpScreen(context: completedViewModel.context)
            .previewDisplayName("Completed")
    }
    
    private static func makeViewModel(state: NitroCatchUpOperationState? = nil) -> NitroCatchUpScreenViewModel {
        let service = NitroCatchUpServiceMock()
        if let state {
            service.operationsSubject.send([.init(id: "preview-job",
                                                  roomID: "!nitro:example.org",
                                                  roomName: "Nitro team",
                                                  mode: .overview,
                                                  startedAt: Date(),
                                                  state: state)])
        }
        return NitroCatchUpScreenViewModel(roomID: "!nitro:example.org",
                                           roomName: "Nitro team",
                                           service: service)
    }
}
