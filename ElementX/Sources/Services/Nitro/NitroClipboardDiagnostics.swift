//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import UIKit

enum NitroClipboardDiagnostics {
    static func report(itemProviders: [NSItemProvider] = UIPasteboard.general.itemProviders,
                       generatedAt: Date = .now,
                       systemName: String = UIDevice.current.systemName,
                       systemVersion: String = UIDevice.current.systemVersion,
                       appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                       buildNumber: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown") async -> String {
        var lines = [
            "# Nitro clipboard diagnostics",
            "",
            "Generated: \(generatedAt.formatted(.iso8601))",
            "System: \(systemName) \(systemVersion)",
            "App: \(appVersion) (\(buildNumber))",
            "Items: \(itemProviders.count)",
            "Content included: no"
        ]
        
        for (index, itemProvider) in itemProviders.enumerated() {
            guard !Task.isCancelled else { break }
            let diagnostics = await NitroMessageCopyFormatter.pasteDiagnostics(from: itemProvider)
            lines.append(contentsOf: [
                "",
                "## Item \(index + 1)",
                "Text paste supported: \(yesNo(diagnostics.supportsTextPaste))",
                "Selected format: \(diagnostics.selectedFormat ?? "none")",
                "Selected type: \(diagnostics.selectedTypeIdentifier ?? "none")",
                "Registered types: \(diagnostics.representations.count)"
            ])
            
            for (typeIndex, representation) in diagnostics.representations.enumerated() {
                let size = representation.conformsToText
                    ? representation.byteCount.map { "\($0) bytes" } ?? "load failed"
                    : "not loaded (non-text)"
                lines.append("\(typeIndex + 1). \(representation.typeIdentifier) — \(size)")
            }
        }
        
        return lines.joined(separator: "\n")
    }
    
    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}
