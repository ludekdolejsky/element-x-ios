//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

final class NitroReminderPreviewServiceMock: NitroReminderPreviewServiceProtocol {
    var loadPreviewsForForceRefreshReturnValue = [NitroReminderPreviewUpdate]()
    private(set) var loadPreviewsForForceRefreshReceivedArguments: (reminders: [NitroReminder], forceRefresh: Bool)?
    var loadPreviewsForForceRefreshClosure: (([NitroReminder], Bool, @escaping @MainActor @Sendable (NitroReminderPreviewUpdate) -> Void) async -> Void)?
    
    func loadPreviews(for reminders: [NitroReminder],
                      forceRefresh: Bool,
                      update: @escaping @MainActor @Sendable (NitroReminderPreviewUpdate) -> Void) async {
        loadPreviewsForForceRefreshReceivedArguments = (reminders, forceRefresh)
        if let loadPreviewsForForceRefreshClosure {
            await loadPreviewsForForceRefreshClosure(reminders, forceRefresh, update)
            return
        }
        for previewUpdate in loadPreviewsForForceRefreshReturnValue {
            guard !Task.isCancelled else { return }
            update(previewUpdate)
        }
    }
}
