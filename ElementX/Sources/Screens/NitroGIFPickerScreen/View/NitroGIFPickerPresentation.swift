//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

struct NitroGIFPickerPresentation: View {
    @State private var viewModel: NitroGIFPickerScreenViewModel
    let onAction: (NitroGIFPickerScreenViewModelAction) -> Void

    init(configuration: NitroGIFConfiguration,
         userID: String,
         onAction: @escaping (NitroGIFPickerScreenViewModelAction) -> Void) {
        _viewModel = State(initialValue: NitroGIFPickerScreenViewModel(userID: userID,
                                                                       service: NitroGIFService(configuration: configuration)))
        self.onAction = onAction
    }

    var body: some View {
        NitroGIFPickerScreen(context: viewModel.context)
            .onReceive(viewModel.actionsPublisher, perform: onAction)
    }
}
