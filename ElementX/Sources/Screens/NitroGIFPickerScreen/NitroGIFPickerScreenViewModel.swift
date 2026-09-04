//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

typealias NitroGIFPickerScreenViewModelType = StateStoreViewModelV2<NitroGIFPickerScreenViewState, NitroGIFPickerScreenViewAction>

final class NitroGIFPickerScreenViewModel: NitroGIFPickerScreenViewModelType, NitroGIFPickerScreenViewModelProtocol {
    private let userID: String
    private let service: NitroGIFServiceProtocol
    private let recentStore: NitroGIFRecentStore

    private var searchTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var hasAppeared = false

    private let actionsSubject = PassthroughSubject<NitroGIFPickerScreenViewModelAction, Never>()
    var actionsPublisher: AnyPublisher<NitroGIFPickerScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    init(userID: String,
         service: NitroGIFServiceProtocol,
         recentStore: NitroGIFRecentStore = .init()) {
        self.userID = userID
        self.service = service
        self.recentStore = recentStore
        super.init(initialViewState: .init())
    }

    override func process(viewAction: NitroGIFPickerScreenViewAction) {
        switch viewAction {
        case .appear:
            guard !hasAppeared else { return }
            hasAppeared = true
            search(query: "", offset: 0, append: false)
        case .cancel:
            stopTasks()
            actionsSubject.send(.dismiss)
        case .loadMore:
            guard let nextOffset = state.nextOffset, !state.isLoadingMore else { return }
            search(query: state.activeQuery, offset: nextOffset, append: true)
        case .search:
            search(query: state.bindings.query, offset: 0, append: false)
        case .select(let result):
            state.selectedResult = result
        case .stop:
            stopTasks()
        case .surpriseMe:
            state.selectedResult = state.results.randomElement()
        case .useSelected:
            downloadSelection()
        }
    }

    private func search(query: String, offset: Int, append: Bool) {
        searchTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if append {
            state.isLoadingMore = true
        } else {
            state.isLoading = true
            state.activeQuery = trimmedQuery
            state.nextOffset = nil
            state.selectedResult = nil
            let recent = trimmedQuery.isEmpty ? recentStore.recentGIFs(for: userID) : []
            state.results = recent
            state.isShowingRecents = !recent.isEmpty
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            let result = await service.search(query: trimmedQuery, offset: offset)
            guard !Task.isCancelled else { return }
            finishSearch(result)
        }
    }

    private func finishSearch(_ result: Result<NitroGIFSearchPage, NitroGIFServiceError>) {
        state.isLoading = false
        state.isLoadingMore = false

        switch result {
        case .success(let page):
            let currentResults = state.results
            let knownIDs = Set(currentResults.map(\.id))
            state.results = currentResults + page.results.filter { !knownIDs.contains($0.id) }
            state.nextOffset = page.nextOffset
        case .failure(.cancelled):
            break
        case .failure:
            state.bindings.alertInfo = .init(id: .searchFailed,
                                             title: UntranslatedL10n.errorNitroGifSearchFailedIos)
        }
    }

    private func downloadSelection() {
        guard let selectedResult = state.selectedResult, downloadTask == nil else { return }
        state.isDownloading = true

        downloadTask = Task { [weak self] in
            guard let self else { return }
            let result = await service.download(selectedResult)
            guard !Task.isCancelled else { return }
            state.isDownloading = false
            downloadTask = nil

            switch result {
            case .success(let url):
                recentStore.record(selectedResult, for: userID)
                actionsSubject.send(.selected(url))
            case .failure(.cancelled):
                break
            case .failure(let error):
                state.bindings.alertInfo = .init(id: .downloadFailed,
                                                 title: downloadErrorTitle(error))
            }
        }
    }

    private func downloadErrorTitle(_ error: NitroGIFServiceError) -> String {
        switch error {
        case .notGIF:
            UntranslatedL10n.errorNitroGifNotGifIos
        case .tooLarge:
            UntranslatedL10n.errorNitroGifTooLargeIos
        case .invalidResponse:
            UntranslatedL10n.errorNitroGifInvalidResponseIos
        default:
            UntranslatedL10n.errorNitroGifDownloadFailedIos
        }
    }

    private func stopTasks() {
        searchTask?.cancel()
        searchTask = nil
        downloadTask?.cancel()
        downloadTask = nil
        state.isLoading = false
        state.isLoadingMore = false
        state.isDownloading = false
    }
}
