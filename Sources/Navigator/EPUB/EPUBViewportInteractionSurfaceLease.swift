//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

struct EPUBViewportInteractionSurfaceLease: Equatable {
    var surfaceIdentifier: UUID
    var layoutGeneration: UInt64
}

/// Runs an asynchronous query only while the same render-surface lease remains
/// elected. The second check is required because actor reentrancy allows
/// pagination or a CSS reflow to replace the surface while `operation` awaits.
@MainActor
func evaluateViewportInteractionSurface<Value>(
    requestedSurfaceIdentifier: UUID,
    requestedLayoutGeneration: UInt64?,
    currentLease: () -> EPUBViewportInteractionSurfaceLease?,
    operation: () async -> Result<Value, Error>
) async -> Result<Value, Error> {
    guard
        let initialLease = currentLease(),
        initialLease.surfaceIdentifier == requestedSurfaceIdentifier,
        requestedLayoutGeneration.map({ $0 == initialLease.layoutGeneration }) ?? true
    else {
        return .failure(EPUBViewportInteractionError.surfaceUnavailable)
    }

    let result = await operation()

    guard currentLease() == initialLease else {
        return .failure(EPUBViewportInteractionError.surfaceUnavailable)
    }
    return result
}
