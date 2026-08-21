//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

/// Orders one native viewport owner's pointer and physical terminal callbacks.
struct ViewportInteractionPointerState {
    struct PointerEnd: Equatable {
        var generation: NavigatorViewportInteractionGeneration
        var cancelled: Bool
        var hasBufferedPhysicalTerminal: Bool
    }

    private var generation: NavigatorViewportInteractionGeneration?
    private var pointerDidEnd = false
    private var hasBufferedPhysicalTerminal = false

    mutating func begin(_ generation: NavigatorViewportInteractionGeneration?) {
        self.generation = generation
        pointerDidEnd = false
        hasBufferedPhysicalTerminal = false
    }

    /// Records the first pointer terminal. Later UIKit terminals for the same
    /// pointer, including an induced cancel after a normal end, are ignored.
    mutating func didEndPointer(cancelled: Bool) -> PointerEnd? {
        guard let generation, !pointerDidEnd else { return nil }

        pointerDidEnd = true
        let result = PointerEnd(
            generation: generation,
            cancelled: cancelled,
            hasBufferedPhysicalTerminal: hasBufferedPhysicalTerminal
        )
        hasBufferedPhysicalTerminal = false
        return result
    }

    /// Records an affirmative physical terminal. A non-decelerating terminal
    /// may be buffered because UIKit can deliver it just before pointer end;
    /// other pre-pointer terminals are stale and ignored.
    mutating func didReachPhysicalTerminal(
        bufferUntilPointerEnd: Bool = false
    ) -> NavigatorViewportInteractionGeneration? {
        guard let generation else { return nil }
        guard pointerDidEnd else {
            if bufferUntilPointerEnd {
                hasBufferedPhysicalTerminal = true
            }
            return nil
        }
        return generation
    }

    /// Finishes the current generation only after its pointer ended.
    mutating func didReportSettlement(
        _ generation: NavigatorViewportInteractionGeneration
    ) -> Bool {
        guard self.generation == generation, pointerDidEnd else { return false }
        reset()
        return true
    }

    mutating func retire() -> NavigatorViewportInteractionGeneration? {
        defer { reset() }
        return generation
    }

    private mutating func reset() {
        generation = nil
        pointerDidEnd = false
        hasBufferedPhysicalTerminal = false
    }
}
