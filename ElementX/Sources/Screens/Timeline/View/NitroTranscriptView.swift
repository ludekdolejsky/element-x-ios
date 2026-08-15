//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Compound
import SwiftUI
import UIKit

struct NitroTranscriptView: View {
    @Environment(\.dismiss) private var dismiss
    
    let info: NitroTranscriptInfo
    let sendToThreadAction: (() -> Void)?
    
    var body: some View {
        ElementNavigationStack {
            VStack(spacing: 24) {
                ScrollView {
                    Text(info.text)
                        .font(.compound.bodyLG)
                        .foregroundStyle(.compound.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                HStack(spacing: 12) {
                    Button(L10n.actionCopy) {
                        UIPasteboard.general.string = info.text
                    }
                    .buttonStyle(.compound(.secondary))
                    
                    if let sendToThreadAction {
                        Button(UntranslatedL10n.actionSendTranscriptToThreadIos) {
                            sendToThreadAction()
                            dismiss()
                        }
                        .buttonStyle(.compound(.primary))
                    }
                }
            }
            .padding(24)
            .background(Color.compound.bgCanvasDefault)
            .navigationTitle(UntranslatedL10n.screenAudioTranscriptTitleIos)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.actionDone) {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct NitroTranscriptView_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        NitroTranscriptView(info: .init(itemID: .event(uniqueID: .init("preview"),
                                                       eventOrTransactionID: .eventID("$preview")),
                                        text: "A sample transcript from an audio message.")) { }
    }
}
