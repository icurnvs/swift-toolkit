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
@Suite("EPUB viewport interaction surface lease")
struct EPUBViewportInteractionSurfaceLeaseTests {
    @Test("an in-flight query drops a result after another surface is elected")
    func electionChangeDropsResult() async {
        let requestedSurface = UUID()
        var currentLease = EPUBViewportInteractionSurfaceLease(
            surfaceIdentifier: requestedSurface,
            layoutGeneration: 7
        )

        let result: Result<String, Error> = await evaluateViewportInteractionSurface(
            requestedSurfaceIdentifier: requestedSurface,
            requestedLayoutGeneration: 7,
            currentLease: { currentLease },
            operation: {
                currentLease = EPUBViewportInteractionSurfaceLease(
                    surfaceIdentifier: UUID(),
                    layoutGeneration: 7
                )
                return .success("former surface")
            }
        )

        #expect(isSurfaceUnavailable(result))
    }

    @Test("an in-flight query drops a result after the surface reflows")
    func layoutChangeDropsResult() async {
        let requestedSurface = UUID()
        var currentLease = EPUBViewportInteractionSurfaceLease(
            surfaceIdentifier: requestedSurface,
            layoutGeneration: 7
        )

        let result: Result<String, Error> = await evaluateViewportInteractionSurface(
            requestedSurfaceIdentifier: requestedSurface,
            requestedLayoutGeneration: 7,
            currentLease: { currentLease },
            operation: {
                currentLease.layoutGeneration = 8
                return .success("stale layout")
            }
        )

        #expect(isSurfaceUnavailable(result))
    }

    @Test("a query returns when its exact surface lease remains elected")
    func stableLeaseReturnsResult() async throws {
        let requestedSurface = UUID()
        let currentLease = EPUBViewportInteractionSurfaceLease(
            surfaceIdentifier: requestedSurface,
            layoutGeneration: 7
        )

        let result: Result<String, Error> = await evaluateViewportInteractionSurface(
            requestedSurfaceIdentifier: requestedSurface,
            requestedLayoutGeneration: 7,
            currentLease: { currentLease },
            operation: { .success("current surface") }
        )

        #expect(try result.get() == "current surface")
    }
}

@MainActor
@Suite("EPUB viewport layout generation seams")
struct EPUBViewportLayoutGenerationTests {
    @Test("effective CSS changes synchronously invalidate the render generation once")
    func effectiveCSSChangeInvalidatesGeneration() {
        let (viewModel, delegate) = makeViewModel()

        viewModel.submitPreferences(.init(fontSize: 1.25))
        #expect(delegate.viewportLayoutChangeCount == 1)

        viewModel.submitPreferences(.init(fontSize: 1.25))
        #expect(delegate.viewportLayoutChangeCount == 1)

        viewModel.submitPreferences(.init(fontSize: 1.5))
        #expect(delegate.viewportLayoutChangeCount == 2)
    }

    @Test("every effective viewport size change synchronously invalidates the render generation")
    func effectiveSizeChangeInvalidatesGeneration() {
        let (viewModel, delegate) = makeViewModel()

        viewModel.viewSizeWillChange(CGSize(width: 320, height: 640))
        #expect(delegate.viewportLayoutChangeCount == 1)

        viewModel.viewSizeWillChange(CGSize(width: 320, height: 640))
        #expect(delegate.viewportLayoutChangeCount == 1)

        viewModel.viewSizeWillChange(CGSize(width: 640, height: 320))
        #expect(delegate.viewportLayoutChangeCount == 2)
    }

    private func makeViewModel() -> (EPUBNavigatorViewModel, ViewModelDelegateSpy) {
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Viewport generation test"),
                readingOrder: [Link(href: "chapter.xhtml", mediaType: .xhtml)]
            )
        )
        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: publication.readingOrder,
            config: .init()
        )
        let delegate = ViewModelDelegateSpy()
        viewModel.delegate = delegate
        return (viewModel, delegate)
    }
}

private func isSurfaceUnavailable<Value>(_ result: Result<Value, Error>) -> Bool {
    guard case let .failure(error) = result else { return false }
    guard case EPUBViewportInteractionError.surfaceUnavailable = error else { return false }
    return true
}

@MainActor
private final class ViewModelDelegateSpy: EPUBNavigatorViewModelDelegate {
    var viewportLayoutChangeCount = 0

    func epubNavigatorViewModelWillChangeViewportLayout(_ viewModel: EPUBNavigatorViewModel) {
        viewportLayoutChangeCount += 1
    }

    func epubNavigatorViewModel(
        _ viewModel: EPUBNavigatorViewModel,
        runScript script: String,
        in scope: EPUBScriptScope
    ) {}

    func epubNavigatorViewModelInvalidatePaginationView(_ viewModel: EPUBNavigatorViewModel) {}

    func epubNavigatorViewModel(
        _ viewModel: EPUBNavigatorViewModel,
        didFailToLoadResourceAt href: RelativeURL,
        withError error: ReadError
    ) {}
}
