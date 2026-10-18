//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Testing
import WebKit

@MainActor
@Suite("EPUB embedded navigation script", .serialized)
struct EPUBEmbeddedNavigationScriptTests {
    @Test("the embedded renderer reports dispatch through WebKit to the native consumer", arguments: ["readium-reflowable", "readium-fixed"])
    func progressionDispatchResult(bundleName: String) async throws {
        let bundleURL = try #require(Bundle.module.url(
            forResource: bundleName,
            withExtension: "js",
            subdirectory: "Assets/Static/scripts"
        ))
        let script = try String(contentsOf: bundleURL, encoding: .utf8)
        let document = NavigationDocument()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.navigationDelegate = document
        webView.configuration.userContentController.add(document, name: "spreadLoadStarted")
        webView.configuration.userContentController.add(document, name: "spreadLoaded")
        defer {
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.navigationDelegate = nil
        }

        try await document.load(in: webView)
        _ = try await webView.evaluateJavaScript(script + "\ntrue;")
        for progression in [-0.1, 1.1] {
            let value = try await webView.evaluateJavaScript("readium.scrollToPosition(\(progression), 'ltr', false)")
            #expect(!EPUBReflowableSpreadView.didResolveNavigation(.success(value)))
            #expect(value as? Bool == false)
        }
        for progression in [0.0, 0.5, 1.0] {
            let value = try await webView.evaluateJavaScript("readium.scrollToPosition(\(progression), 'ltr', false)")
            #expect(EPUBReflowableSpreadView.didResolveNavigation(.success(value)))
            #expect(value as? Bool == true)
        }
        // A true result acknowledges dispatch, without asserting settled geometry.
    }
}

@MainActor
private final class NavigationDocument: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var loadContinuation: CheckedContinuation<Void, Error>?

    func load(in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.loadHTMLString("<!doctype html><html><head></head><body><p id='target'>Navigation fixture</p></body></html>", baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: error)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}

    private func finish(with error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}
