//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum NitroGIFPickerScreenViewModelAction {
    case dismiss
    case selected(URL)
}

enum NitroGIFPickerScreenAlertID: Hashable {
    case searchFailed
    case downloadFailed
}

struct NitroGIFPickerScreenViewState: BindableState {
    var results = [NitroGIFResult]()
    var selectedResult: NitroGIFResult?
    var activeQuery = ""
    var nextOffset: Int?
    var isLoading = false
    var isLoadingMore = false
    var isDownloading = false
    var isShowingRecents = false
    var bindings = NitroGIFPickerScreenViewStateBindings()

    var resultSectionTitle: String {
        if !activeQuery.isEmpty {
            UntranslatedL10n.screenNitroGifResultsIos
        } else if isShowingRecents {
            UntranslatedL10n.screenNitroGifRecentAndTrendingIos
        } else {
            UntranslatedL10n.screenNitroGifTrendingIos
        }
    }
}

struct NitroGIFPickerScreenViewStateBindings {
    var query = ""
    var alertInfo: AlertInfo<NitroGIFPickerScreenAlertID>?
}

enum NitroGIFPickerScreenViewAction {
    case appear
    case cancel
    case loadMore
    case search
    case select(NitroGIFResult)
    case stop
    case surpriseMe
    case useSelected
}
