//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import Kingfisher
import SwiftUI

struct NitroGIFPickerScreen: View {
    @Bindable var context: NitroGIFPickerScreenViewModel.Context

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        ElementNavigationStack {
            VStack(spacing: 0) {
                searchBar
                content
            }
            .background(Color.compound.bgCanvasDefault)
            .navigationTitle(UntranslatedL10n.screenNitroGifTitleIos)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionCancel) {
                        context.send(viewAction: .cancel)
                    }
                    .disabled(context.viewState.isDownloading)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controls
            }
            .alert(item: $context.alertInfo)
            .task { context.send(viewAction: .appear) }
            .onDisappear { context.send(viewAction: .stop) }
            .interactiveDismissDisabled(context.viewState.isDownloading)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField(UntranslatedL10n.screenNitroGifSearchIos, text: $context.query)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { context.send(viewAction: .search) }

            Button {
                context.send(viewAction: .search)
            } label: {
                CompoundIcon(\.search)
            }
            .buttonStyle(.compound(.secondary, size: .medium))
            .accessibilityLabel(L10n.actionSearch)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if context.viewState.isLoading, context.viewState.results.isEmpty {
            Spacer()
            ProgressView(UntranslatedL10n.screenNitroGifLoadingIos)
            Spacer()
        } else if context.viewState.results.isEmpty {
            Spacer()
            Text(UntranslatedL10n.screenNitroGifNoResultsIos)
                .font(.compound.bodyLG)
                .foregroundStyle(.compound.textSecondary)
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(context.viewState.resultSectionTitle)
                        .font(.compound.bodySMSemibold)
                        .foregroundStyle(.compound.textSecondary)

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(context.viewState.results) { result in
                            resultButton(result)
                        }
                    }

                    if context.viewState.nextOffset != nil {
                        Button(L10n.actionLoadMore) {
                            context.send(viewAction: .loadMore)
                        }
                        .buttonStyle(.compound(.secondary, size: .medium))
                        .frame(maxWidth: .infinity)
                        .disabled(context.viewState.isLoadingMore)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private func resultButton(_ result: NitroGIFResult) -> some View {
        Button {
            context.send(viewAction: .select(result))
        } label: {
            KFImage(result.thumbnailURL)
                .placeholder {
                    Rectangle()
                        .fill(Color.compound.bgSubtleSecondary)
                        .overlay { ProgressView() }
                }
                .resizable()
                .scaledToFill()
                .frame(height: 100)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    if context.viewState.selectedResult?.id == result.id {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.compound.borderInteractivePrimary, lineWidth: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(result.altText)
        .accessibilityAddTraits(context.viewState.selectedResult?.id == result.id ? .isSelected : [])
    }

    private func selectedPreview(_ result: NitroGIFResult) -> some View {
        KFAnimatedImage(source: .network(result.previewURL))
            .placeholder { ProgressView() }
            .configure { $0.contentMode = .scaleAspectFit }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(result.altText)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let selectedResult = context.viewState.selectedResult {
                selectedPreview(selectedResult)
            }

            HStack(spacing: 12) {
                Button(UntranslatedL10n.actionNitroGifSurpriseMeIos) {
                    context.send(viewAction: .surpriseMe)
                }
                .buttonStyle(.compound(.secondary, size: .medium))
                .disabled(context.viewState.results.isEmpty || context.viewState.isDownloading)

                Button(UntranslatedL10n.actionNitroGifUseIos) {
                    context.send(viewAction: .useSelected)
                }
                .buttonStyle(.compound(.primary, size: .medium))
                .disabled(context.viewState.selectedResult == nil || context.viewState.isDownloading)
            }

            if context.viewState.isDownloading {
                ProgressView()
            }

            Text(UntranslatedL10n.screenNitroGifPoweredByGiphyIos)
                .font(.compound.bodyXS)
                .foregroundStyle(.compound.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.bar)
    }
}

struct NitroGIFPickerScreen_Previews: PreviewProvider, TestablePreview {
    static let result = NitroGIFResult(id: "preview",
                                       title: "Preview GIF",
                                       altText: "Preview GIF",
                                       thumbnailURL: "https://media.giphy.com/media/preview/200_s.gif",
                                       previewURL: "https://media.giphy.com/media/preview/200.gif",
                                       downloadURL: "https://media.giphy.com/media/preview/giphy.gif")
    static let viewModel = NitroGIFPickerScreenViewModel(userID: "@alice:example.com",
                                                         service: NitroGIFPickerPreviewService(result: result))

    static var previews: some View {
        NitroGIFPickerScreen(context: viewModel.context)
    }
}

private nonisolated struct NitroGIFPickerPreviewService: NitroGIFServiceProtocol {
    let result: NitroGIFResult

    func search(query: String, offset: Int) async -> Result<NitroGIFSearchPage, NitroGIFServiceError> {
        .success(.init(results: [result], nextOffset: nil))
    }

    func download(_ result: NitroGIFResult) async -> Result<URL, NitroGIFServiceError> {
        .failure(.network)
    }
}
