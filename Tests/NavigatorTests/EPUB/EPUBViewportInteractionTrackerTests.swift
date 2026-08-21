//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing
import UIKit

@MainActor
@Suite("EPUB viewport interaction tracker")
struct EPUBViewportInteractionTrackerTests {
    @Test("non-decelerating interaction reports began, pointer end, then settlement")
    func nonDeceleratingOrdering() {
        let initial = fingerprint()
        var current = initial
        let events = EventSink()
        let tracker = makeTracker(current: { current }, events: events)
        let owner = makeOwner(.spread)

        let generation = tracker.didRecognize(owner: owner, initialFingerprint: .available(initial))
        tracker.didEndPointer(generation: generation, owner: owner, cancelled: false)

        #expect(events.events.map(\.phase) == [
            .began(initialFingerprint: .available(initial)),
            .pointerEnded,
        ])
        #expect(events.events.allSatisfy { $0.generation == generation })

        current.contentGeometry.contentOffset.y = 120
        tracker.didSettle(generation: generation, owner: owner)

        #expect(events.events.last?.generation == generation)
        #expect(events.events.last?.phase == .settled(.available(current)))
    }

    @Test("decelerating interaction remains pending after pointer end")
    func deceleratingOrdering() {
        let initial = fingerprint()
        let events = EventSink()
        let tracker = makeTracker(current: { initial }, events: events)
        let owner = makeOwner(.spread)

        let generation = tracker.didRecognize(owner: owner, initialFingerprint: .available(initial))
        tracker.didEndPointer(generation: generation, owner: owner, cancelled: false)

        #expect(events.events.count == 2)
        #expect(events.events.last?.phase == .pointerEnded)

        tracker.didSettle(generation: generation, owner: owner)
        #expect(events.events.count == 3)
        #expect(events.events.last?.phase == .settled(.available(initial)))
    }

    @Test("recognized cancellation is a terminal but not settlement")
    func cancellationOrdering() {
        let initial = fingerprint()
        let events = EventSink()
        let tracker = makeTracker(current: { initial }, events: events)
        let owner = makeOwner(.spread)

        let generation = tracker.didRecognize(owner: owner, initialFingerprint: .available(initial))
        tracker.didEndPointer(generation: generation, owner: owner, cancelled: true)

        #expect(events.events.last?.phase == .pointerCancelled)
        #expect(events.events.count == 2)

        tracker.didSettle(generation: generation, owner: owner)
        #expect(events.events.last?.phase == .settled(.available(initial)))
    }

    @Test("nested scroll owners coalesce into one generation and both must settle")
    func nestedOwnersCoalesce() {
        let initial = fingerprint()
        let events = EventSink()
        let tracker = makeTracker(current: { initial }, events: events)
        let spread = makeOwner(.spread)
        let pagination = makeOwner(.pagination)

        let innerGeneration = tracker.didRecognize(owner: spread, initialFingerprint: .available(initial))
        let outerGeneration = tracker.didRecognize(owner: pagination, initialFingerprint: .available(initial))

        #expect(innerGeneration == outerGeneration)
        #expect(events.events.count == 1)

        tracker.didEndPointer(generation: innerGeneration, owner: spread, cancelled: false)
        tracker.didSettle(generation: innerGeneration, owner: spread)
        #expect(events.events.count == 1)

        tracker.didEndPointer(generation: outerGeneration, owner: pagination, cancelled: false)
        #expect(events.events.last?.phase == .pointerEnded)
        tracker.didSettle(generation: outerGeneration, owner: pagination)
        #expect(events.events.last?.phase == .settled(.available(initial)))
    }

    @Test("an inner cancel can hand off to an outer owner before the public terminal")
    func nestedOwnerHandoffCoalescesTerminal() {
        let initial = fingerprint()
        let events = EventSink()
        let scheduler = HandoffScheduler()
        let tracker = EPUBViewportInteractionTracker(
            currentSettlement: { .available(initial) },
            scheduleOwnerHandoff: { scheduler.schedule($0) },
            onEvent: { events.events.append($0) }
        )
        let spread = makeOwner(.spread)
        let pagination = makeOwner(.pagination)

        let generation = tracker.didRecognize(owner: spread, initialFingerprint: .available(initial))
        tracker.didEndPointer(generation: generation, owner: spread, cancelled: true)
        #expect(events.events.count == 1)

        #expect(
            tracker.didRecognize(owner: pagination, initialFingerprint: .available(initial)) == generation
        )
        scheduler.runNext()
        #expect(events.events.count == 1)

        tracker.didEndPointer(generation: generation, owner: pagination, cancelled: false)
        #expect(events.events.count == 1)
        scheduler.runNext()
        #expect(events.events.last?.phase == .pointerEnded)

        tracker.didSettle(generation: generation, owner: spread)
        tracker.didSettle(generation: generation, owner: pagination)
        #expect(events.events.last?.phase == .settled(.available(initial)))
    }

    @Test("all nested cancellations produce one public cancellation")
    func nestedOwnersAllCancel() {
        let initial = fingerprint()
        let events = EventSink()
        let tracker = makeTracker(current: { initial }, events: events)
        let spread = makeOwner(.spread)
        let pagination = makeOwner(.pagination)

        let generation = tracker.didRecognize(owner: spread, initialFingerprint: .available(initial))
        #expect(
            tracker.didRecognize(owner: pagination, initialFingerprint: .available(initial)) == generation
        )
        tracker.didEndPointer(generation: generation, owner: spread, cancelled: true)
        tracker.didEndPointer(generation: generation, owner: pagination, cancelled: true)

        #expect(events.events.map(\.phase) == [
            .began(initialFingerprint: .available(initial)),
            .pointerCancelled,
        ])
    }

    @Test("an exact return is affirmed by equal live fingerprints")
    func exactUnchanged() {
        let initial = fingerprint(contentOffset: CGPoint(x: 0, y: 50))
        let events = EventSink()
        let tracker = makeTracker(current: { initial }, events: events)
        let owner = makeOwner(.spread)

        let generation = tracker.didRecognize(owner: owner, initialFingerprint: .available(initial))
        tracker.didEndPointer(generation: generation, owner: owner, cancelled: false)
        tracker.didSettle(generation: generation, owner: owner)

        #expect(events.events.last?.phase == .settled(.available(initial)))
        guard case let .settled(.available(final)) = events.events.last?.phase else {
            Issue.record("Expected an available settlement")
            return
        }
        #expect(final == initial)
    }

    @Test("cross-spine settlement uses the elected destination surface")
    func crossSpineElection() {
        let initialSurface = UUID()
        let finalSurface = UUID()
        let initial = fingerprint(pageIndex: 2, surfaceIdentifier: initialSurface)
        var current = initial
        let events = EventSink()
        let tracker = makeTracker(current: { current }, events: events)
        let pagination = makeOwner(.pagination)

        let generation = tracker.didRecognize(owner: pagination, initialFingerprint: .available(initial))
        tracker.didEndPointer(generation: generation, owner: pagination, cancelled: false)

        current = fingerprint(pageIndex: 3, surfaceIdentifier: finalSurface)
        #expect(events.events.last?.phase == .pointerEnded)

        // PaginationView sends this only after destination PageView.go has
        // completed and the elected destination surface is ready.
        tracker.didSettle(generation: generation, owner: pagination)

        #expect(events.events.last?.phase == .settled(.available(current)))
        #expect(current.pageIndex == 3)
        #expect(current.surfaceIdentifier == finalSurface)
    }

    @Test("cross-spine pagination carries the generation after the former surface retires")
    func crossSpineRetiresFormerSurface() {
        let initial = fingerprint(pageIndex: 2)
        let destination = fingerprint(pageIndex: 3)
        let events = EventSink()
        let tracker = makeTracker(current: { destination }, events: events)
        let spread = makeOwner(.spread)
        let pagination = makeOwner(.pagination)

        let generation = tracker.didRecognize(owner: spread, initialFingerprint: .available(initial))
        #expect(tracker.didRecognize(owner: pagination, initialFingerprint: .available(initial)) == generation)
        tracker.didEndPointer(generation: generation, owner: pagination, cancelled: false)

        tracker.didRetire(generation: generation, owner: spread)
        tracker.didSettle(generation: generation, owner: spread)
        #expect(events.events.last?.phase == .pointerEnded)

        tracker.didSettle(generation: generation, owner: pagination)
        #expect(events.events.last?.phase == .settled(.available(destination)))
    }

    @Test("a newer gesture supersedes stale terminals from the old generation")
    func supersessionDropsStaleSettlement() {
        let initial = fingerprint()
        let events = EventSink()
        let tracker = makeTracker(current: { initial }, events: events)
        let owner = makeOwner(.spread)

        let first = tracker.didRecognize(owner: owner, initialFingerprint: .available(initial))
        tracker.didEndPointer(generation: first, owner: owner, cancelled: false)
        let second = tracker.didRecognize(owner: owner, initialFingerprint: .available(initial))

        #expect(second > first)

        tracker.didSettle(generation: first, owner: owner)
        #expect(events.events.contains(where: {
            $0.generation == first && isSettled($0.phase)
        }) == false)

        tracker.didEndPointer(generation: second, owner: owner, cancelled: false)
        tracker.didSettle(generation: second, owner: owner)
        #expect(events.events.last?.generation == second)
        #expect(isSettled(events.events.last?.phase) == true)
    }

    @Test("a stale physical terminal before the current pointer end is ignored")
    func staleSettlementBeforePointerEnd() {
        let initial = fingerprint()
        let events = EventSink()
        let tracker = makeTracker(current: { initial }, events: events)
        let owner = makeOwner(.spread)

        let generation = tracker.didRecognize(owner: owner, initialFingerprint: .available(initial))
        tracker.didSettle(generation: generation, owner: owner)
        tracker.didEndPointer(generation: generation, owner: owner, cancelled: false)

        #expect(events.events.count == 2)
        #expect(events.events.last?.phase == .pointerEnded)

        tracker.didSettle(generation: generation, owner: owner)
        #expect(isSettled(events.events.last?.phase) == true)
    }

    @Test("retiring the only surface produces typed unavailable settlement")
    func retiredSurfaceIsUnavailable() {
        let initial = fingerprint()
        let events = EventSink()
        let tracker = makeTracker(current: { initial }, events: events)
        let owner = makeOwner(.spread)

        let generation = tracker.didRecognize(owner: owner, initialFingerprint: .available(initial))
        tracker.didEndPointer(generation: generation, owner: owner, cancelled: false)
        tracker.didRetire(generation: generation, owner: owner)

        #expect(events.events.last?.phase == .settled(.unavailable(.surfaceRetired)))
    }

    @Test("a missing live render query produces typed unavailable settlement")
    func liveFingerprintUnavailable() {
        let initial = fingerprint()
        let events = EventSink()
        let tracker = EPUBViewportInteractionTracker(
            currentSettlement: { .unavailable(.surfaceNotReady) },
            scheduleOwnerHandoff: { $0() },
            onEvent: { events.events.append($0) }
        )
        let owner = makeOwner(.spread)

        let generation = tracker.didRecognize(owner: owner, initialFingerprint: .available(initial))
        tracker.didEndPointer(generation: generation, owner: owner, cancelled: false)
        tracker.didSettle(generation: generation, owner: owner)

        #expect(events.events.last?.phase == .settled(.unavailable(.surfaceNotReady)))
    }

    @Test("recognition mints a generation when its initial fingerprint is unavailable")
    func initialFingerprintUnavailable() {
        let events = EventSink()
        let tracker = EPUBViewportInteractionTracker(
            currentSettlement: { .unavailable(.invalidGeometry) },
            scheduleOwnerHandoff: { $0() },
            onEvent: { events.events.append($0) }
        )
        let owner = makeOwner(.spread)

        let generation = tracker.didRecognize(
            owner: owner,
            initialFingerprint: .unavailable(.invalidGeometry)
        )

        #expect(generation.rawValue == 1)
        #expect(events.events.first?.phase == .began(initialFingerprint: .unavailable(.invalidGeometry)))

        tracker.didEndPointer(generation: generation, owner: owner, cancelled: false)
        tracker.didSettle(generation: generation, owner: owner)
        #expect(events.events.last?.phase == .settled(.unavailable(.invalidGeometry)))
    }

    @Test("non-finite geometry is ineligible for exact fingerprint evidence")
    func nonFiniteGeometryIsInvalid() {
        let valid = fingerprint()
        var invalidViewport = valid
        invalidViewport.viewportFrame.origin.x = .infinity
        var invalidBounds = valid
        invalidBounds.paginationGeometry.bounds.size.height = .nan
        var invalidOffset = valid
        invalidOffset.paginationGeometry.contentOffset.y = .infinity
        var invalidContentSize = valid
        invalidContentSize.contentGeometry.contentSize.width = .nan
        var invalidInset = valid
        invalidInset.contentGeometry.adjustedContentInset.bottom = .infinity
        var invalidZoom = valid
        invalidZoom.contentGeometry.zoomScale = .nan

        #expect(valid.hasFiniteGeometry)
        #expect([
            invalidViewport,
            invalidBounds,
            invalidOffset,
            invalidContentSize,
            invalidInset,
            invalidZoom,
        ].allSatisfy { !$0.hasFiniteGeometry })
    }

    @Test("scene departure cancels active pointers once and preserves late settlement")
    func sceneDepartureCancellation() {
        let initial = fingerprint()
        let events = EventSink()
        let tracker = makeTracker(current: { initial }, events: events)
        let owner = makeOwner(.spread)

        let generation = tracker.didRecognize(owner: owner, initialFingerprint: .available(initial))
        var ownerState = ViewportInteractionPointerState()
        ownerState.begin(generation)
        tracker.didCancelActivePointersForSceneDeparture()
        tracker.didCancelActivePointersForSceneDeparture()
        if let localEnd = ownerState.didEndPointer(cancelled: true) {
            tracker.didEndPointer(
                generation: localEnd.generation,
                owner: owner,
                cancelled: localEnd.cancelled
            )
        } else {
            Issue.record("Expected the native owner to record scene cancellation")
        }

        #expect(events.events.map(\.phase) == [
            .began(initialFingerprint: .available(initial)),
            .pointerCancelled,
        ])

        #expect(ownerState.didReachPhysicalTerminal() == generation)
        let didReportSettlement = ownerState.didReportSettlement(generation)
        #expect(didReportSettlement)
        tracker.didSettle(generation: generation, owner: owner)
        tracker.didSettle(generation: generation, owner: owner)
        #expect(events.events.last?.phase == .settled(.available(initial)))
        #expect(events.events.count == 3)
    }

    @Test("normal pointer-up wins over UIKit's later induced cancellation")
    func normalEndWinsInducedCancellation() {
        let generation = NavigatorViewportInteractionGeneration(rawValue: 8)
        var state = ViewportInteractionPointerState()
        state.begin(generation)

        let normalEnd = state.didEndPointer(cancelled: false)
        let inducedCancellation = state.didEndPointer(cancelled: true)

        #expect(normalEnd?.generation == generation)
        #expect(normalEnd?.cancelled == false)
        #expect(inducedCancellation == nil)
        #expect(state.didReachPhysicalTerminal() == generation)
        let didReportSettlement = state.didReportSettlement(generation)
        #expect(didReportSettlement)
    }

    @Test("only a non-decelerating physical terminal buffers before pointer end")
    func physicalTerminalBuffering() {
        let generation = NavigatorViewportInteractionGeneration(rawValue: 9)
        var state = ViewportInteractionPointerState()
        state.begin(generation)

        #expect(state.didReachPhysicalTerminal(bufferUntilPointerEnd: true) == nil)
        #expect(state.didEndPointer(cancelled: false)?.hasBufferedPhysicalTerminal == true)

        state.begin(generation)
        #expect(state.didReachPhysicalTerminal() == nil)
        #expect(state.didEndPointer(cancelled: false)?.hasBufferedPhysicalTerminal == false)
    }

    @Test("programmatic motion terminals cannot create an interaction")
    func programmaticNavigationIsExcluded() {
        let initial = fingerprint()
        let events = EventSink()
        let tracker = makeTracker(current: { initial }, events: events)
        let owner = makeOwner(.pagination)

        // Programmatic scrolling never calls didRecognize. UIKit's
        // scrollViewDidEndScrollingAnimation is intentionally not wired to the
        // tracker, so a terminal without a recognized generation is ignored.
        tracker.didSettle(
            generation: NavigatorViewportInteractionGeneration(rawValue: 1),
            owner: owner
        )

        #expect(events.events.isEmpty)
    }

    @Test("all lifecycle edges use the system-uptime nanosecond domain")
    func monotonicEventTimestamps() {
        let initial = fingerprint()
        let events = EventSink()
        var timestamps = [1000 as UInt64, 1250, 1900]
        let tracker = EPUBViewportInteractionTracker(
            currentSettlement: { .available(initial) },
            uptimeNanoseconds: { timestamps.removeFirst() },
            scheduleOwnerHandoff: { $0() },
            onEvent: { events.events.append($0) }
        )
        let owner = makeOwner(.spread)

        let generation = tracker.didRecognize(owner: owner, initialFingerprint: .available(initial))
        tracker.didEndPointer(generation: generation, owner: owner, cancelled: false)
        tracker.didSettle(generation: generation, owner: owner)

        #expect(events.events.map(\.uptimeNanoseconds) == [1000, 1250, 1900])
    }
}

@MainActor
private func makeTracker(
    current: @escaping () -> NavigatorViewportFingerprint,
    events: EventSink
) -> EPUBViewportInteractionTracker {
    EPUBViewportInteractionTracker(
        currentSettlement: { .available(current()) },
        scheduleOwnerHandoff: { $0() },
        onEvent: { events.events.append($0) }
    )
}

/// Reference storage lets an escaping event callback update a test's event log
/// without relying on shared global state.
@MainActor
private final class EventSink {
    var events: [NavigatorViewportInteractionEvent] = []
}

@MainActor
private final class HandoffScheduler {
    private var actions: [@MainActor @Sendable () -> Void] = []

    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
        actions.append(action)
    }

    func runNext() {
        guard !actions.isEmpty else {
            Issue.record("Expected a scheduled owner-handoff action")
            return
        }
        actions.removeFirst()()
    }
}

private func makeOwner(
    _ kind: EPUBViewportInteractionTracker.Owner.Kind
) -> EPUBViewportInteractionTracker.Owner {
    .init(kind: kind, identifier: UUID())
}

private func isSettled(_ phase: NavigatorViewportInteractionEvent.Phase?) -> Bool {
    guard case .settled = phase else { return false }
    return true
}

private func fingerprint(
    pageIndex: Int = 0,
    surfaceIdentifier: UUID = UUID(),
    contentOffset: CGPoint = .zero
) -> NavigatorViewportFingerprint {
    let geometry = NavigatorViewportFingerprint.Geometry(
        bounds: CGRect(x: 0, y: 0, width: 320, height: 640),
        contentOffset: contentOffset,
        contentSize: CGSize(width: 320, height: 2400),
        adjustedContentInset: .zero,
        zoomScale: 1
    )
    return NavigatorViewportFingerprint(
        navigatorIdentifier: UUID(uuidString: "CECC9A76-ED99-45D4-ACF1-E0BEA73DDE8A")!,
        layoutGeneration: 4,
        layout: .scrolled,
        pageIndex: pageIndex,
        surfaceIdentifier: surfaceIdentifier,
        canonicalHREF: AnyURL(string: "chapter.xhtml")!,
        viewportFrame: geometry.bounds,
        paginationGeometry: geometry,
        contentGeometry: geometry
    )
}
