//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

/// Observes pointer ownership edges from a native scroll view without becoming
/// its gesture recognizer delegate.
@MainActor final class ViewportInteractionPanObserver: NSObject {
    private let onBegan: () -> Void
    private let onCancelled: () -> Void

    init(
        recognizer: UIPanGestureRecognizer,
        onBegan: @escaping () -> Void,
        onCancelled: @escaping () -> Void
    ) {
        self.onBegan = onBegan
        self.onCancelled = onCancelled
        super.init()
        recognizer.addTarget(self, action: #selector(didChangeState(_:)))
    }

    @objc private func didChangeState(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onBegan()
        case .cancelled, .failed:
            onCancelled()
        case .possible, .changed, .ended:
            break
        @unknown default:
            onCancelled()
        }
    }
}
