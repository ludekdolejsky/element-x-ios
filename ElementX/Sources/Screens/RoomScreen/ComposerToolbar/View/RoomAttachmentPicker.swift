//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import Foundation
import SwiftUI
import WysiwygComposer

struct NitroGIFPickerPresentationConfiguration {
    let userID: String
    let serviceConfiguration: NitroGIFConfiguration
    let onSelected: (URL) -> Void
}

struct RoomAttachmentPicker: View {
    @ObservedObject var context: ComposerToolbarViewModel.Context
    let onCreateNitroTask: (() -> Void)?
    let nitroGIFPickerConfiguration: NitroGIFPickerPresentationConfiguration?

    @State private var isNitroGIFPickerPresented = false
    @State private var pendingNitroGIFURL: URL?

    init(context: ComposerToolbarViewModel.Context,
         onCreateNitroTask: (() -> Void)? = nil,
         nitroGIFPickerConfiguration: NitroGIFPickerPresentationConfiguration? = nil) {
        self.context = context
        self.onCreateNitroTask = onCreateNitroTask
        self.nitroGIFPickerConfiguration = nitroGIFPickerConfiguration
    }
    
    var body: some View {
        // Use a menu instead of the popover/sheet shown in Figma because overriding the colour scheme
        // results in a rendering bug on 17.1: https://github.com/element-hq/element-x-ios/issues/2157
        Menu {
            menuContent
        } label: {
            CompoundIcon(\.plus,
                         size: Compound.supportsGlass ? .medium : .small,
                         relativeTo: .compound.headingLG)
        }
        .buttonStyle(ComposerToolbarButtonStyle())
        .accessibilityLabel(L10n.actionAddToTimeline)
        .accessibilityIdentifier(A11yIdentifiers.roomScreen.composerToolbar.openComposeOptions)
        .sheet(isPresented: $isNitroGIFPickerPresented, onDismiss: completeNitroGIFSelection) {
            if let nitroGIFPickerConfiguration {
                NitroGIFPickerPresentation(configuration: nitroGIFPickerConfiguration.serviceConfiguration,
                                           userID: nitroGIFPickerConfiguration.userID) { action in
                    switch action {
                    case .dismiss:
                        isNitroGIFPickerPresented = false
                    case .selected(let url):
                        pendingNitroGIFURL = url
                        isNitroGIFPickerPresented = false
                    }
                }
                .presentationDetents([.large])
            }
        }
    }
    
    var menuContent: some View {
        VStack(alignment: .leading, spacing: 0.0) {
            Button {
                context.send(viewAction: .enableTextFormatting)
            } label: {
                Label(L10n.screenRoomAttachmentTextFormatting, icon: \.textFormatting)
            }
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerTextFormatting)

            if context.viewState.canCreateNitroTask, let onCreateNitroTask {
                Button {
                    onCreateNitroTask()
                } label: {
                    Label(UntranslatedL10n.actionCreateNitroTaskIos, icon: \.checkCircle)
                }
            }

            Button {
                context.send(viewAction: .attach(.poll))
            } label: {
                Label(L10n.screenRoomAttachmentSourcePoll, icon: \.polls)
            }
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerPoll)
            
            if context.viewState.canSendStandaloneEmoji {
                Button {
                    context.send(viewAction: .attach(.customEmoji))
                } label: {
                    Label(UntranslatedL10n.screenRoomAttachmentSourceCustomEmoji, icon: \.reaction)
                }
            }
            
            if nitroGIFPickerConfiguration != nil {
                Button {
                    isNitroGIFPickerPresented = true
                } label: {
                    Label(UntranslatedL10n.actionNitroGifIos, icon: \.image)
                }
                .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerNitroGIF)
            }

            if context.viewState.isLocationSharingEnabled {
                Button {
                    context.send(viewAction: .attach(.location))
                } label: {
                    Label(L10n.screenRoomAttachmentSourceLocation, icon: \.locationPin)
                }
                .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerLocation)
            }
            
            Button {
                context.send(viewAction: .attach(.file))
            } label: {
                Label(L10n.screenRoomAttachmentSourceFiles, icon: \.attachment)
            }
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerDocuments)
            
            Button {
                context.send(viewAction: .attach(.photoLibrary))
            } label: {
                Label(L10n.screenRoomAttachmentSourceGallery, icon: \.image)
            }
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerPhotoLibrary)
            
            Button {
                context.send(viewAction: .attach(.camera))
            } label: {
                Label(L10n.screenRoomAttachmentSourceCamera, icon: \.takePhoto)
            }
            .accessibilityIdentifier(A11yIdentifiers.roomScreen.attachmentPickerCamera)
        }
    }

    private func completeNitroGIFSelection() {
        guard let pendingNitroGIFURL else { return }
        self.pendingNitroGIFURL = nil
        nitroGIFPickerConfiguration?.onSelected(pendingNitroGIFURL)
    }
}

struct RoomAttachmentPicker_Previews: PreviewProvider, TestablePreview {
    static let viewModel = makeViewModel()
    
    static func makeViewModel() -> ComposerToolbarViewModel {
        let appSettings = AppSettings.volatile()
        
        return ComposerToolbarViewModel(roomProxy: JoinedRoomProxyMock(.init()),
                                        wysiwygViewModel: WysiwygComposerViewModel(),
                                        completionSuggestionService: CompletionSuggestionServiceMock(configuration: .init()),
                                        mediaProvider: MediaProviderMock(.init()),
                                        mentionDisplayHelper: ComposerMentionDisplayHelper.mock,
                                        appSettings: appSettings,
                                        analyticsService: AnalyticsServiceMock(.init()),
                                        composerDraftService: ComposerDraftServiceMock(.init()))
    }
    
    static var previews: some View {
        RoomAttachmentPicker(context: viewModel.context)
    }
}
