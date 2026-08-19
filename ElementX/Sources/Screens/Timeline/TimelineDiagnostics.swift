//
// Copyright 2026 Nitrovery Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import UIKit

final class TimelineDiagnostics {
    private struct RenderState: Equatable {
        let modelItems: Int
        let snapshotItems: Int
        let visibleCells: Int
        let tableRows: Int
        let tableAlpha: CGFloat
        let tableOpacity: Float
        let tablePresentationOpacity: Float
        let cellAlpha: CGFloat
        let cellOpacity: Float
        let cellPresentationOpacity: Float
        let hostingAlpha: CGFloat
        let hostingOpacity: Float
        let hostingPresentationOpacity: Float
        let parentAlpha: CGFloat
        let parentPresentationOpacity: Float
        let hasHiddenParent: Bool
        let tableIsHidden: Bool
        let isInWindow: Bool
        let animationKeys: String
        let animationsDisabled: Bool
        let bannerCompositingDisabled: Bool
        
        var overlayText: String {
            "M\(modelItems) S\(snapshotItems) V\(visibleCells) R\(tableRows)\n" +
                "T\(tablePresentationOpacity.formatted) C\(cellPresentationOpacity.formatted) " +
                "H\(hostingPresentationOpacity.formatted) P\(parentPresentationOpacity.formatted) K\(animationKeys.isEmpty ? "0" : "1") " +
                "A\(animationsDisabled ? "0" : "1") B\(bannerCompositingDisabled ? "0" : "1")"
        }
        
        var logDescription: String {
            "model=\(modelItems) snapshot=\(snapshotItems) visible=\(visibleCells) rows=\(tableRows) " +
                "table(alpha=\(tableAlpha.formatted),opacity=\(tableOpacity.formatted),presentation=\(tablePresentationOpacity.formatted),hidden=\(tableIsHidden)) " +
                "cell(alpha=\(cellAlpha.formatted),opacity=\(cellOpacity.formatted),presentation=\(cellPresentationOpacity.formatted)) " +
                "hosting(alpha=\(hostingAlpha.formatted),opacity=\(hostingOpacity.formatted),presentation=\(hostingPresentationOpacity.formatted)) " +
                "parents(alpha=\(parentAlpha.formatted),presentation=\(parentPresentationOpacity.formatted),hidden=\(hasHiddenParent)) " +
                "window=\(isInWindow) animations=\(animationKeys.isEmpty ? "none" : animationKeys) " +
                "timelineAnimationsDisabled=\(animationsDisabled) bannerCompositingDisabled=\(bannerCompositingDisabled)"
        }
    }

    private weak var tableView: UITableView?
    private let overlayLabel = UILabel()
    private var timer: Timer?
    private var lastState: RenderState?
    private var isRunning = false
    
    var modelItemCount = 0
    var snapshotItemCount = 0
    var animationsDisabled = false
    var bannerCompositingDisabled = false
    
    init(tableView: UITableView) {
        self.tableView = tableView
        configureOverlay()
    }
    
    isolated deinit {
        timer?.invalidate()
    }
    
    func setEnabled(_ isEnabled: Bool, in containerView: UIView?) {
        guard isEnabled else {
            stop()
            return
        }
        
        guard let containerView else { return }
        start(in: containerView)
    }
    
    func start(in containerView: UIView) {
        guard !isRunning else { return }
        isRunning = true
        lastState = nil
        installOverlay(in: containerView)
        sample(reason: "start")
        
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sample(reason: "watchdog")
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    func stop() {
        guard isRunning else { return }
        sample(reason: "stop", forceLog: true)
        isRunning = false
        timer?.invalidate()
        timer = nil
        overlayLabel.removeFromSuperview()
        MXLog.info("TimelineDiagnostics stopped")
    }
    
    func recordSnapshot(animated: Bool) {
        sample(reason: "snapshot animated=\(animated)", forceLog: true)
    }
    
    func recordManualAction(_ action: String) {
        sample(reason: action, forceLog: true)
    }

    private func configureOverlay() {
        overlayLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        overlayLabel.layer.cornerRadius = 6
        overlayLabel.clipsToBounds = true
        overlayLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        overlayLabel.textColor = .white
        overlayLabel.numberOfLines = 2
        overlayLabel.textAlignment = .center
        overlayLabel.isAccessibilityElement = false
    }
    
    private func installOverlay(in containerView: UIView) {
        guard overlayLabel.superview !== containerView else { return }
        overlayLabel.removeFromSuperview()
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(overlayLabel)
        NSLayoutConstraint.activate([
            overlayLabel.leadingAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            overlayLabel.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            overlayLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 154),
            overlayLabel.heightAnchor.constraint(equalToConstant: 36)
        ])
    }
    
    private func sample(reason: String, forceLog: Bool = false) {
        guard isRunning, let tableView else { return }
        
        let visibleCells = tableView.visibleCells.compactMap { $0 as? TimelineItemCell }
        let cell = visibleCells.first
        let hostingView = cell?.contentView.subviews.first
        let parentViews = sequence(first: tableView.superview) { $0?.superview }.compactMap { $0 }
        let parentAlpha = parentViews.reduce(CGFloat(1)) { $0 * $1.alpha }
        let parentPresentationOpacity = parentViews.reduce(Float(1)) {
            $0 * ($1.layer.presentation()?.opacity ?? $1.layer.opacity)
        }
        let animationKeys = ([tableView.layer, cell?.layer, cell?.contentView.layer, hostingView?.layer] + parentViews.map(\.layer))
            .compactMap { $0?.animationKeys() }
            .flatMap { $0 }
            .sorted()
            .joined(separator: ",")
        let tableRows = (0..<tableView.numberOfSections).reduce(0) { count, section in
            count + tableView.numberOfRows(inSection: section)
        }
        let state = RenderState(modelItems: modelItemCount,
                                snapshotItems: snapshotItemCount,
                                visibleCells: visibleCells.count,
                                tableRows: tableRows,
                                tableAlpha: tableView.alpha,
                                tableOpacity: tableView.layer.opacity,
                                tablePresentationOpacity: tableView.layer.presentation()?.opacity ?? tableView.layer.opacity,
                                cellAlpha: cell?.alpha ?? 1,
                                cellOpacity: cell?.layer.opacity ?? 1,
                                cellPresentationOpacity: cell?.layer.presentation()?.opacity ?? cell?.layer.opacity ?? 1,
                                hostingAlpha: hostingView?.alpha ?? 1,
                                hostingOpacity: hostingView?.layer.opacity ?? 1,
                                hostingPresentationOpacity: hostingView?.layer.presentation()?.opacity ?? hostingView?.layer.opacity ?? 1,
                                parentAlpha: parentAlpha,
                                parentPresentationOpacity: parentPresentationOpacity,
                                hasHiddenParent: parentViews.contains(where: \.isHidden),
                                tableIsHidden: tableView.isHidden,
                                isInWindow: tableView.window != nil,
                                animationKeys: animationKeys,
                                animationsDisabled: animationsDisabled,
                                bannerCompositingDisabled: bannerCompositingDisabled)
        
        overlayLabel.text = state.overlayText
        overlayLabel.superview?.bringSubviewToFront(overlayLabel)
        
        guard forceLog || state != lastState else { return }
        lastState = state
        MXLog.info("TimelineDiagnostics [\(reason)] \(state.logDescription)")
    }
}

private extension BinaryFloatingPoint {
    var formatted: String {
        String(format: "%.2f", Double(self))
    }
}
