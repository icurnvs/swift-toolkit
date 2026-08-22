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
@Suite("EPUB programmatic navigation")
struct EPUBProgrammaticNavigationTests {
    @Test("same-resource fragment navigation reports whether the DOM target resolves")
    func sameResourceFragmentResolution() async {
        let knownIDs: Set<String> = ["target"]

        let missing = await resolve(
            locator(fragments: ["missing"]),
            knownIDs: knownIDs
        )
        let real = await resolve(
            locator(fragments: ["target"]),
            knownIDs: knownIDs
        )

        #expect(!missing)
        #expect(real)
    }

    @Test("same-resource progression navigation reports a completed operation")
    func sameResourceProgressionResolution() async {
        let resolved = await resolve(locator(progression: 0.5), knownIDs: [])

        #expect(resolved)
    }

    @Test("JavaScript dispatch succeeds only with an affirmative navigation result")
    func javaScriptNavigationResult() {
        #expect(EPUBReflowableSpreadView.didResolveNavigation(.success(true)))
        #expect(!EPUBReflowableSpreadView.didResolveNavigation(.success(false)))
        #expect(!EPUBReflowableSpreadView.didResolveNavigation(.success(())))
        #expect(!EPUBReflowableSpreadView.didResolveNavigation(.failure(TestError.expected)))
    }

    @Test("cross-resource pagination propagates the destination page result")
    func crossResourceResolution() async throws {
        let paginationView = PaginationView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            preloadPreviousPositionCount: 0,
            preloadNextPositionCount: 0,
            isScrollEnabled: true
        )
        let delegate = PaginationDelegate(behaviors: [
            .immediate(true),
            .immediate(true),
            .pending,
        ])
        paginationView.delegate = delegate
        paginationView.reloadAtIndex(
            0,
            location: .start,
            pageCount: 3,
            readingProgression: .ltr
        )

        for _ in 0 ..< 1_000 where paginationView.currentView == nil {
            await Task.yield()
        }
        _ = try #require(paginationView.currentView)

        let result = NavigationResult()
        let navigation = Task { @MainActor in
            let resolved = await paginationView.goToIndex(
                2,
                location: .locator(locator(fragments: ["missing"])),
                options: .init(animated: false)
            )
            result.value = resolved
            return resolved
        }

        for _ in 0 ..< 1_000 where delegate.pages[2]?.hasPendingNavigation != true {
            await Task.yield()
        }
        let destinationPage = try #require(delegate.pages[2])
        try #require(destinationPage.hasPendingNavigation)

        #expect(result.value == nil)
        destinationPage.completePendingNavigation(with: false)
        let resolved = await navigation.value

        #expect(!resolved)
        #expect(result.value == false)
        #expect(destinationPage.receivedLocations == [
            .locator(locator(fragments: ["missing"])),
        ])
    }

    @Test("superseded cross-resource navigation cannot complete as current")
    func supersededCrossResourceResolution() async throws {
        let paginationView = PaginationView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            preloadPreviousPositionCount: 0,
            preloadNextPositionCount: 0,
            isScrollEnabled: true
        )
        let delegate = PaginationDelegate(behaviors: [
            .immediate(true),
            .immediate(true),
            .pending,
        ])
        paginationView.delegate = delegate
        paginationView.reloadAtIndex(
            0,
            location: .start,
            pageCount: 3,
            readingProgression: .ltr
        )

        for _ in 0 ..< 1_000 where paginationView.currentView == nil {
            await Task.yield()
        }
        _ = try #require(paginationView.currentView)

        let navigation = Task { @MainActor in
            await paginationView.goToIndex(
                2,
                location: .locator(locator(progression: 0.5)),
                options: .init(animated: false)
            )
        }

        for _ in 0 ..< 1_000 where delegate.pages[2]?.hasPendingNavigation != true {
            await Task.yield()
        }
        let stalePage = try #require(delegate.pages[2])
        try #require(stalePage.hasPendingNavigation)

        paginationView.reloadAtIndex(
            1,
            location: .start,
            pageCount: 3,
            readingProgression: .ltr
        )
        stalePage.completePendingNavigation(with: true)

        let staleResult = await navigation.value
        #expect(!staleResult)
        #expect(paginationView.currentIndex == 1)
    }

    private func resolve(_ locator: Locator, knownIDs: Set<String>) async -> Bool {
        await resolveEPUBReflowableLocation(
            locator,
            scrollToLocator: { $0.text.highlight == "known text" },
            scrollToTagID: { knownIDs.contains($0) },
            scrollToProgression: { 0 ... 1 ~= $0 }
        )
    }

    private func locator(
        fragments: [String] = [],
        progression: Double? = nil,
        text: Locator.Text = .init()
    ) -> Locator {
        Locator(
            href: RelativeURL(path: "chapter.xhtml")!,
            mediaType: .xhtml,
            locations: .init(fragments: fragments, progression: progression),
            text: text
        )
    }
}

private enum TestError: Error {
    case expected
}

@MainActor
private final class PaginationDelegate: PaginationViewDelegate {
    private let behaviors: [PageViewSpy.Behavior]
    private(set) var pages: [Int: PageViewSpy] = [:]

    init(behaviors: [PageViewSpy.Behavior]) {
        self.behaviors = behaviors
    }

    func paginationView(
        _ paginationView: PaginationView,
        pageViewAtIndex index: Int
    ) -> (UIView & PageView)? {
        let page = PageViewSpy(behavior: behaviors[index])
        pages[index] = page
        return page
    }

    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {}

    func paginationView(
        _ paginationView: PaginationView,
        positionCountAtIndex index: Int
    ) -> Int {
        1
    }

    func paginationViewViewportInteractionDidBegin(
        _ paginationView: PaginationView
    ) -> NavigatorViewportInteractionGeneration? {
        nil
    }

    func paginationView(
        _ paginationView: PaginationView,
        viewportInteraction generation: NavigatorViewportInteractionGeneration,
        pointerDidEndCancelled cancelled: Bool
    ) {}

    func paginationView(
        _ paginationView: PaginationView,
        prepareViewportInteractionSettlement generation: NavigatorViewportInteractionGeneration
    ) async -> Bool {
        false
    }

    func paginationView(
        _ paginationView: PaginationView,
        viewportInteractionDidSettle generation: NavigatorViewportInteractionGeneration
    ) {}
}

@MainActor
private final class PageViewSpy: UIView, PageView {
    enum Behavior {
        case immediate(Bool)
        case pending
    }

    let behavior: Behavior
    private(set) var receivedLocations: [PageLocation] = []
    private var pendingContinuation: CheckedContinuation<Bool, Never>?

    var hasPendingNavigation: Bool {
        pendingContinuation != nil
    }

    init(behavior: Behavior) {
        self.behavior = behavior
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func go(to location: PageLocation, animated: Bool) async -> Bool {
        receivedLocations.append(location)
        switch behavior {
        case let .immediate(result):
            return result
        case .pending:
            return await withCheckedContinuation { continuation in
                pendingContinuation = continuation
            }
        }
    }

    func completePendingNavigation(with result: Bool) {
        pendingContinuation?.resume(returning: result)
        pendingContinuation = nil
    }
}

@MainActor
private final class NavigationResult {
    var value: Bool?
}
