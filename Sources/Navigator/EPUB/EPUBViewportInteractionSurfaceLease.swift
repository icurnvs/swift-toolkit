//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

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

/// Computes a required live locator while the requested render-surface lease
/// remains elected. A missing locator is distinct from a stale lease so callers
/// can fail closed without falling back to the navigator's cached location.
@MainActor
func evaluateViewportInteractionLocation(
    requestedSurfaceIdentifier: UUID,
    requestedLayoutGeneration: UInt64,
    currentLease: () -> EPUBViewportInteractionSurfaceLease?,
    operation: () async -> Locator?
) async -> Result<Locator, Error> {
    let result: Result<Locator?, Error> = await evaluateViewportInteractionSurface(
        requestedSurfaceIdentifier: requestedSurfaceIdentifier,
        requestedLayoutGeneration: requestedLayoutGeneration,
        currentLease: currentLease,
        operation: { await .success(operation()) }
    )

    switch result {
    case let .success(locator?):
        return .success(locator)
    case .success(nil):
        return .failure(EPUBViewportInteractionError.locationUnavailable)
    case let .failure(error):
        return .failure(error)
    }
}

/// Publishes a physical settlement only after its destination-surface facts
/// are ready and the pending interaction is still current.
@MainActor
@discardableResult
func publishViewportInteractionSettlementWhenReady(
    prepare: () async -> Bool,
    isStillCurrent: () -> Bool,
    publish: () -> Void
) async -> Bool {
    guard await prepare(), isStillCurrent() else {
        return false
    }
    publish()
    return true
}
