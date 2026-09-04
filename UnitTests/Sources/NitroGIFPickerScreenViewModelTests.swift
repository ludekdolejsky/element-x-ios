//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import Testing

struct NitroGIFPickerScreenViewModelTests {
    @Test
    func loadsRecentsBeforeTrendingAndDeduplicatesResults() async throws {
        let recent = makeResult(id: "recent")
        let trending = makeResult(id: "trending")
        let userDefaults = try makeUserDefaults()
        let recentStore = NitroGIFRecentStore(userDefaults: userDefaults)
        recentStore.record(recent, for: "@alice:example.org")
        let service = NitroGIFPickerServiceMock(searchResult: .success(.init(results: [recent, trending], nextOffset: 24)))
        let viewModel = NitroGIFPickerScreenViewModel(userID: "@alice:example.org", service: service, recentStore: recentStore)
        let loaded = deferFulfillment(viewModel.context.observe(\.viewState.isLoading)) { !$0 }

        viewModel.context.send(viewAction: .appear)
        #expect(viewModel.context.viewState.results == [recent])
        try await loaded.fulfill()

        #expect(viewModel.context.viewState.results == [recent, trending])
        #expect(viewModel.context.viewState.isShowingRecents)
        #expect(viewModel.context.viewState.nextOffset == 24)
    }

    @Test
    func handsDownloadedGIFToTheMediaFlow() async throws {
        let gif = makeResult(id: "selected")
        let downloadedURL = FileManager.default.temporaryDirectory.appending(path: "selected.gif")
        let service = NitroGIFPickerServiceMock(searchResult: .success(.init(results: [gif], nextOffset: nil)),
                                                downloadResult: .success(downloadedURL))
        let viewModel = try NitroGIFPickerScreenViewModel(userID: "@alice:example.org",
                                                          service: service,
                                                          recentStore: NitroGIFRecentStore(userDefaults: makeUserDefaults()))
        let selected = deferFulfillment(viewModel.actionsPublisher) { action in
            guard case .selected(let url) = action else { return false }
            return url == downloadedURL
        }

        viewModel.context.send(viewAction: .select(gif))
        viewModel.context.send(viewAction: .useSelected)
        try await selected.fulfill()

        #expect(await service.downloadedIDs == [gif.id])
    }

    @Test
    func cancellingStopsLocalWorkAndDismisses() async throws {
        let service = CancellableNitroGIFPickerServiceMock()
        let viewModel = try NitroGIFPickerScreenViewModel(userID: "@alice:example.org",
                                                          service: service,
                                                          recentStore: NitroGIFRecentStore(userDefaults: makeUserDefaults()))
        let dismissed = deferFulfillment(viewModel.actionsPublisher) { action in
            if case .dismiss = action {
                return true
            }
            return false
        }
        let searchStarted = deferFulfillment(service.searchStarted, timeout: .seconds(1)) { _ in true }
        let searchCancelled = deferFulfillment(service.searchCancelled, timeout: .seconds(1)) { _ in true }

        viewModel.context.send(viewAction: .appear)
        try await searchStarted.fulfill()
        viewModel.context.send(viewAction: .cancel)
        try await searchCancelled.fulfill()
        try await dismissed.fulfill()
    }

    private func makeUserDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "NitroGIFPickerScreenViewModelTests.\(UUID().uuidString)"))
    }

    private func makeResult(id: String) -> NitroGIFResult {
        let url = URL(string: "https://media.example.org/\(id).gif")! // swiftlint:disable:this force_unwrapping
        return .init(id: id,
                     title: "GIF \(id)",
                     altText: "GIF \(id)",
                     thumbnailURL: url,
                     previewURL: url,
                     downloadURL: url)
    }
}

private actor NitroGIFPickerServiceMock: NitroGIFServiceProtocol {
    let searchResult: Result<NitroGIFSearchPage, NitroGIFServiceError>
    let downloadResult: Result<URL, NitroGIFServiceError>
    private(set) var downloadedIDs = [String]()

    init(searchResult: Result<NitroGIFSearchPage, NitroGIFServiceError>,
         downloadResult: Result<URL, NitroGIFServiceError> = .failure(.network)) {
        self.searchResult = searchResult
        self.downloadResult = downloadResult
    }

    func search(query: String, offset: Int) async -> Result<NitroGIFSearchPage, NitroGIFServiceError> {
        searchResult
    }

    func download(_ result: NitroGIFResult) async -> Result<URL, NitroGIFServiceError> {
        downloadedIDs.append(result.id)
        return downloadResult
    }
}

private actor CancellableNitroGIFPickerServiceMock: NitroGIFServiceProtocol {
    nonisolated let searchStarted: AsyncStream<Void>
    private let searchStartedContinuation: AsyncStream<Void>.Continuation
    nonisolated let searchCancelled: AsyncStream<Void>
    private let searchCancelledContinuation: AsyncStream<Void>.Continuation

    init() {
        (searchStarted, searchStartedContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (searchCancelled, searchCancelledContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func search(query: String, offset: Int) async -> Result<NitroGIFSearchPage, NitroGIFServiceError> {
        searchStartedContinuation.yield()
        searchStartedContinuation.finish()
        defer { searchCancelledContinuation.finish() }

        do {
            try await Task.sleep(for: .seconds(2))
            return .success(.init(results: [], nextOffset: nil))
        } catch is CancellationError {
            searchCancelledContinuation.yield()
            return .failure(.cancelled)
        } catch {
            return .failure(.network)
        }
    }

    func download(_ result: NitroGIFResult) async -> Result<URL, NitroGIFServiceError> {
        .failure(.network)
    }
}
