//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Dispatch
import Foundation
import ReadiumShared
import UIKit

/// A visual navigator that reports the lifecycle of user-driven viewport
/// interactions.
///
/// The interaction generation is independent from navigation commands. In
/// particular, programmatic calls to ``Navigator/go(to:options:)`` do not
/// produce viewport interaction events.
public protocol ViewportInteractionObservingNavigator: VisualNavigator {
    /// An exact snapshot of the currently rendered viewport, or `nil` while no
    /// rendered surface is ready or its geometry cannot be represented safely.
    ///
    /// A fresh snapshot is produced for every access.
    var viewportInteractionFingerprint: NavigatorViewportFingerprint? { get }

    /// Stable identity of the currently elected native render surface, or
    /// `nil` before the viewport hierarchy is installed.
    var viewportInteractionSurfaceIdentifier: UUID? { get }
}

/// Delegate for receiving user-driven viewport interaction updates from any
/// ``ViewportInteractionObservingNavigator``.
@MainActor public protocol ViewportInteractionObservingNavigatorDelegate: AnyObject {
    /// Called for each lifecycle edge of a recognized viewport interaction.
    func navigator(
        _ navigator: any ViewportInteractionObservingNavigator,
        didReceive event: NavigatorViewportInteractionEvent
    )
}

public extension ViewportInteractionObservingNavigatorDelegate {
    func navigator(
        _ navigator: any ViewportInteractionObservingNavigator,
        didReceive event: NavigatorViewportInteractionEvent
    ) {}
}

/// A monotonically increasing user viewport interaction identifier scoped to
/// one navigator instance.
public struct NavigatorViewportInteractionGeneration: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (
        lhs: NavigatorViewportInteractionGeneration,
        rhs: NavigatorViewportInteractionGeneration
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A lifecycle edge for one recognized user viewport interaction.
public struct NavigatorViewportInteractionEvent: Equatable {
    public enum Phase: Equatable {
        /// A viewport-moving gesture was recognized.
        case began(initialFingerprint: NavigatorViewportInteractionInitialFingerprint)

        /// The recognized pointer ended. This is not a settlement signal.
        case pointerEnded

        /// The recognized pointer was cancelled. This is not a settlement
        /// signal.
        case pointerCancelled

        /// Every participating native viewport owner reached an affirmative
        /// physical terminal, or the final fingerprint was unavailable.
        case settled(NavigatorViewportInteractionSettlement)
    }

    public var generation: NavigatorViewportInteractionGeneration
    public var phase: Phase

    /// Monotonic event time in the system-uptime nanosecond domain used by
    /// `DispatchTime.now().uptimeNanoseconds`.
    public var uptimeNanoseconds: UInt64

    public init(
        generation: NavigatorViewportInteractionGeneration,
        phase: Phase,
        uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.generation = generation
        self.phase = phase
        self.uptimeNanoseconds = uptimeNanoseconds
    }
}

/// The exact render evidence available when a viewport interaction begins.
public enum NavigatorViewportInteractionInitialFingerprint: Equatable {
    /// A live render fingerprint captured when the gesture was recognized.
    case available(NavigatorViewportFingerprint)

    /// The gesture was recognized, but an exact initial fingerprint could not
    /// be produced safely.
    case unavailable(NavigatorViewportInteractionUnavailability)
}

/// The evidence produced when a viewport interaction physically settles.
public enum NavigatorViewportInteractionSettlement: Equatable {
    /// A live render fingerprint captured at physical settlement.
    ///
    /// Equality with the interaction's initial fingerprint affirmatively proves
    /// that the rendered viewport returned to the exact same geometry.
    case available(NavigatorViewportFingerprint)

    /// The native interaction ended without a render surface that could be
    /// fingerprinted safely.
    case unavailable(NavigatorViewportInteractionUnavailability)
}

/// Why an exact interaction fingerprint could not be produced.
public enum NavigatorViewportInteractionUnavailability: String, Equatable, Sendable {
    /// The navigator has not installed its viewport hierarchy.
    case navigatorNotReady

    /// The elected render surface exists but is not ready for a live query.
    case surfaceNotReady

    /// Native viewport geometry contained a non-finite scalar.
    case invalidGeometry

    /// Every native owner participating in the interaction was retired before
    /// settlement.
    case surfaceRetired
}

/// Exact native render geometry captured at one instant.
public struct NavigatorViewportFingerprint: Equatable {
    /// Native scroll geometry for one viewport layer.
    public struct Geometry: Equatable {
        public var bounds: CGRect
        public var contentOffset: CGPoint
        public var contentSize: CGSize
        public var adjustedContentInset: UIEdgeInsets
        public var zoomScale: CGFloat

        public init(
            bounds: CGRect,
            contentOffset: CGPoint,
            contentSize: CGSize,
            adjustedContentInset: UIEdgeInsets,
            zoomScale: CGFloat
        ) {
            self.bounds = bounds
            self.contentOffset = contentOffset
            self.contentSize = contentSize
            self.adjustedContentInset = adjustedContentInset
            self.zoomScale = zoomScale
        }

        /// Whether every native geometry scalar is finite.
        public var hasFiniteValues: Bool {
            bounds.hasFiniteValues
                && contentOffset.hasFiniteValues
                && contentSize.hasFiniteValues
                && adjustedContentInset.hasFiniteValues
                && zoomScale.isFinite
        }
    }

    public enum Layout: String, Equatable, Sendable {
        case paginated
        case scrolled
    }

    /// Stable identity for the navigator session.
    public var navigatorIdentifier: UUID

    /// Generation of the rendered layout hierarchy. This changes when spreads
    /// are reloaded or reflowed.
    public var layoutGeneration: UInt64

    public var layout: Layout

    /// Index of the elected spread/page in the outer pagination container.
    public var pageIndex: Int

    /// Stable identity of the elected rendered WebView surface.
    public var surfaceIdentifier: UUID

    /// Canonical HREF rendered by the elected surface.
    public var canonicalHREF: AnyURL

    /// Bounds of the elected surface converted into navigator coordinates.
    public var viewportFrame: CGRect

    /// Native geometry of the outer page/spread pagination container.
    public var paginationGeometry: Geometry

    /// Native geometry of the elected rendered content surface.
    public var contentGeometry: Geometry

    public init(
        navigatorIdentifier: UUID,
        layoutGeneration: UInt64,
        layout: Layout,
        pageIndex: Int,
        surfaceIdentifier: UUID,
        canonicalHREF: AnyURL,
        viewportFrame: CGRect,
        paginationGeometry: Geometry,
        contentGeometry: Geometry
    ) {
        self.navigatorIdentifier = navigatorIdentifier
        self.layoutGeneration = layoutGeneration
        self.layout = layout
        self.pageIndex = pageIndex
        self.surfaceIdentifier = surfaceIdentifier
        self.canonicalHREF = canonicalHREF
        self.viewportFrame = viewportFrame
        self.paginationGeometry = paginationGeometry
        self.contentGeometry = contentGeometry
    }

    /// Whether every geometry scalar in this fingerprint is finite.
    public var hasFiniteGeometry: Bool {
        viewportFrame.hasFiniteValues
            && paginationGeometry.hasFiniteValues
            && contentGeometry.hasFiniteValues
    }
}

private extension CGPoint {
    var hasFiniteValues: Bool {
        x.isFinite && y.isFinite
    }
}

private extension CGSize {
    var hasFiniteValues: Bool {
        width.isFinite && height.isFinite
    }
}

private extension CGRect {
    var hasFiniteValues: Bool {
        origin.hasFiniteValues && size.hasFiniteValues
    }
}

private extension UIEdgeInsets {
    var hasFiniteValues: Bool {
        top.isFinite && left.isFinite && bottom.isFinite && right.isFinite
    }
}
