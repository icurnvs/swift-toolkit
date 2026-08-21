//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Dispatch
import Foundation

/// Coalesces the nested native scroll owners of one EPUB viewport gesture into
/// a single navigator-level interaction generation.
@MainActor final class EPUBViewportInteractionTracker {
    struct Owner: Hashable {
        enum Kind: Hashable {
            case pagination
            case spread
        }

        var kind: Kind
        var identifier: UUID
    }

    private struct ActiveInteraction {
        var generation: NavigatorViewportInteractionGeneration
        var owners: Set<Owner>
        var activePointerOwners: Set<Owner>
        var settledOwners: Set<Owner> = []
        var normallyEndedOwners: Set<Owner> = []
        var cancelledOwners: Set<Owner> = []
        var terminal: NavigatorViewportInteractionEvent.Phase?
        var pendingTerminalIdentifier: UInt64?
        var lastPointerTerminalUptimeNanoseconds: UInt64?
        var unavailableReason: NavigatorViewportInteractionUnavailability?
    }

    private var nextGeneration: UInt64 = 0
    private var nextPendingTerminalIdentifier: UInt64 = 0
    private var active: ActiveInteraction?

    private let currentSettlement: () -> NavigatorViewportInteractionSettlement
    private let uptimeNanoseconds: () -> UInt64
    private let scheduleOwnerHandoff: (@escaping @MainActor @Sendable () -> Void) -> Void
    private let onEvent: (NavigatorViewportInteractionEvent) -> Void

    init(
        currentSettlement: @escaping () -> NavigatorViewportInteractionSettlement,
        uptimeNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        scheduleOwnerHandoff: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = { action in
            DispatchQueue.main.async(execute: action)
        },
        onEvent: @escaping (NavigatorViewportInteractionEvent) -> Void
    ) {
        self.currentSettlement = currentSettlement
        self.uptimeNanoseconds = uptimeNanoseconds
        self.scheduleOwnerHandoff = scheduleOwnerHandoff
        self.onEvent = onEvent
    }

    /// Starts a new generation, or joins the active generation when another
    /// nested owner recognizes the same still-active pointer.
    func didRecognize(
        owner: Owner,
        initialFingerprint: NavigatorViewportInteractionInitialFingerprint
    ) -> NavigatorViewportInteractionGeneration {
        if
            var active,
            active.terminal == nil,
            !active.activePointerOwners.isEmpty || !active.owners.contains(owner)
        {
            active.owners.insert(owner)
            active.activePointerOwners.insert(owner)
            active.pendingTerminalIdentifier = nil
            self.active = active
            return active.generation
        }

        precondition(nextGeneration < .max, "Viewport interaction generation exhausted")
        nextGeneration += 1
        let generation = NavigatorViewportInteractionGeneration(rawValue: nextGeneration)
        active = ActiveInteraction(
            generation: generation,
            owners: [owner],
            activePointerOwners: [owner]
        )
        emit(
            generation: generation,
            phase: .began(initialFingerprint: initialFingerprint)
        )
        return generation
    }

    func didEndPointer(
        generation: NavigatorViewportInteractionGeneration,
        owner: Owner,
        cancelled: Bool
    ) {
        guard
            var active,
            active.generation == generation,
            active.owners.contains(owner),
            active.terminal == nil,
            active.activePointerOwners.remove(owner) != nil
        else {
            return
        }

        if cancelled {
            active.cancelledOwners.insert(owner)
        } else {
            active.normallyEndedOwners.insert(owner)
        }
        active.lastPointerTerminalUptimeNanoseconds = uptimeNanoseconds()
        self.active = active
        scheduleTerminalIfPossible(for: generation)
    }

    /// Cancels every still-active native owner when the scene departs without
    /// retiring the interaction. Late physical settlements can still finish
    /// the same generation.
    func didCancelActivePointersForSceneDeparture() {
        guard var active, active.terminal == nil else { return }

        active.cancelledOwners.formUnion(active.activePointerOwners)
        active.activePointerOwners.removeAll()
        active.pendingTerminalIdentifier = nil
        active.terminal = .pointerCancelled
        let timestamp = uptimeNanoseconds()
        active.lastPointerTerminalUptimeNanoseconds = timestamp
        self.active = active
        emit(
            generation: active.generation,
            phase: .pointerCancelled,
            uptimeNanoseconds: timestamp
        )
        finishIfPossible()
    }

    /// Records an affirmative native physical terminal for one owner.
    ///
    /// A terminal arriving before the tracker observes pointer end or centrally
    /// cancels the pointer is stale (for example, a late deceleration callback
    /// from a superseded gesture) and is ignored.
    func didSettle(
        generation: NavigatorViewportInteractionGeneration,
        owner: Owner
    ) {
        guard
            var active,
            active.generation == generation,
            active.owners.contains(owner),
            !active.activePointerOwners.contains(owner)
        else {
            return
        }

        active.settledOwners.insert(owner)
        self.active = active
        finishIfPossible()
    }

    /// Removes a render surface from an active interaction. Other nested owners
    /// can continue carrying the generation (for example, the outer pagination
    /// owner during a cross-spine transition).
    func didRetire(
        generation: NavigatorViewportInteractionGeneration,
        owner: Owner
    ) {
        guard
            var active,
            active.generation == generation,
            active.owners.remove(owner) != nil
        else {
            return
        }

        let retiredActivePointer = active.activePointerOwners.remove(owner) != nil
        active.settledOwners.remove(owner)
        if retiredActivePointer {
            active.cancelledOwners.insert(owner)
            active.lastPointerTerminalUptimeNanoseconds = uptimeNanoseconds()
        }
        if active.owners.isEmpty {
            active.unavailableReason = .surfaceRetired
        }
        self.active = active
        if retiredActivePointer {
            scheduleTerminalIfPossible(for: generation)
        }
        finishIfPossible()
    }

    private func scheduleTerminalIfPossible(
        for generation: NavigatorViewportInteractionGeneration
    ) {
        guard
            var active,
            active.generation == generation,
            active.terminal == nil,
            active.activePointerOwners.isEmpty
        else {
            return
        }

        precondition(nextPendingTerminalIdentifier < .max, "Viewport terminal identifier exhausted")
        nextPendingTerminalIdentifier += 1
        let identifier = nextPendingTerminalIdentifier
        active.pendingTerminalIdentifier = identifier
        self.active = active

        scheduleOwnerHandoff { [weak self] in
            self?.emitPendingTerminal(generation: generation, identifier: identifier)
        }
    }

    private func emitPendingTerminal(
        generation: NavigatorViewportInteractionGeneration,
        identifier: UInt64
    ) {
        guard
            var active,
            active.generation == generation,
            active.terminal == nil,
            active.activePointerOwners.isEmpty,
            active.pendingTerminalIdentifier == identifier
        else {
            return
        }

        let terminal: NavigatorViewportInteractionEvent.Phase = active.normallyEndedOwners.isEmpty
            ? .pointerCancelled
            : .pointerEnded
        let timestamp = active.lastPointerTerminalUptimeNanoseconds ?? uptimeNanoseconds()
        active.terminal = terminal
        active.pendingTerminalIdentifier = nil
        self.active = active
        emit(
            generation: generation,
            phase: terminal,
            uptimeNanoseconds: timestamp
        )
        finishIfPossible()
    }

    private func finishIfPossible() {
        guard
            let active,
            active.terminal != nil,
            active.owners.isSubset(of: active.settledOwners)
        else {
            return
        }

        let settlement = active.unavailableReason
            .map(NavigatorViewportInteractionSettlement.unavailable)
            ?? currentSettlement()
        self.active = nil
        emit(generation: active.generation, phase: .settled(settlement))
    }

    private func emit(
        generation: NavigatorViewportInteractionGeneration,
        phase: NavigatorViewportInteractionEvent.Phase,
        uptimeNanoseconds: UInt64? = nil
    ) {
        onEvent(.init(
            generation: generation,
            phase: phase,
            uptimeNanoseconds: uptimeNanoseconds ?? self.uptimeNanoseconds()
        ))
    }
}
