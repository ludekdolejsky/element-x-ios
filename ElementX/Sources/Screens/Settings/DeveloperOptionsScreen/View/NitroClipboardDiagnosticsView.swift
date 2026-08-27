//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI
import UIKit

struct NitroClipboardDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report: String?
    
    var body: some View {
        ElementNavigationStack {
            Group {
                if let report {
                    ScrollView {
                        Text(report)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(UntranslatedL10n.screenDeveloperOptionsClipboardDiagnosticsIos)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.actionDone, action: dismiss.callAsFunction)
                }
                if let report {
                    ToolbarItem(placement: .primaryAction) {
                        Button(L10n.actionCopy) {
                            UIPasteboard.general.string = report
                        }
                    }
                }
            }
            .task {
                report = await NitroClipboardDiagnostics.report()
            }
        }
    }
}
