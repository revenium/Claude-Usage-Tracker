//
//  ConsoleAuthWebView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-03-01.
//

import SwiftUI
import WebKit

// MARK: - Cookie Result

struct ConsoleCookieResult {
    let sessionKey: String
    let expiryDate: Date?
}

// MARK: - WKWebView Wrapper

struct ConsoleAuthWebView: NSViewRepresentable {
    let loginURL: URL
    let cookieDomain: String
    let onCookieFound: (ConsoleCookieResult) -> Void

    /// Present as desktop Safari. The default WKWebView user agent identifies
    /// the app as an embedded web view, which Google's sign-in flow rejects
    /// outright (403 "disallowed_useragent") and which can trigger extra bot
    /// challenges on the login page.
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = Self.safariUserAgent

        // The login page is a single-page app: after the user signs in, the
        // session cookie is set from an API response without a new main-frame
        // navigation, so didFinish alone never sees it. Observe the cookie
        // store directly so the cookie is detected whenever it lands.
        let cookieStore = config.websiteDataStore.httpCookieStore
        cookieStore.add(context.coordinator)
        context.coordinator.observedCookieStore = cookieStore

        webView.load(URLRequest(url: loginURL))

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObservingCookieStore()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cookieDomain: cookieDomain, onCookieFound: onCookieFound)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let cookieDomain: String
        let onCookieFound: (ConsoleCookieResult) -> Void
        weak var observedCookieStore: WKHTTPCookieStore?
        private var foundCookie = false

        init(cookieDomain: String, onCookieFound: @escaping (ConsoleCookieResult) -> Void) {
            self.cookieDomain = cookieDomain
            self.onCookieFound = onCookieFound
        }

        func stopObservingCookieStore() {
            observedCookieStore?.remove(self)
            observedCookieStore = nil
        }

        // MARK: WKHTTPCookieStoreObserver

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !foundCookie else { return }
            checkForSessionCookie(in: cookieStore)
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !foundCookie else { return }
            checkForSessionCookie(in: webView.configuration.websiteDataStore.httpCookieStore)
        }

        // MARK: WKUIDelegate

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Handle SSO popups by loading in the same webview
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        // MARK: Cookie detection

        /// Pure matcher, kept separate so it is unit-testable.
        static func sessionCookieResult(
            in cookies: [HTTPCookie],
            matching cookieDomain: String
        ) -> ConsoleCookieResult? {
            for cookie in cookies
            where cookie.name == "sessionKey" && cookie.domain.contains(cookieDomain) {
                return ConsoleCookieResult(
                    sessionKey: cookie.value,
                    expiryDate: cookie.expiresDate
                )
            }
            return nil
        }

        private func checkForSessionCookie(in cookieStore: WKHTTPCookieStore) {
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.foundCookie else { return }

                guard
                    let result = Coordinator.sessionCookieResult(
                        in: cookies,
                        matching: self.cookieDomain
                    )
                else { return }

                self.foundCookie = true
                self.stopObservingCookieStore()
                DispatchQueue.main.async {
                    self.onCookieFound(result)
                }
            }
        }
    }
}

// MARK: - Auth Sheet

struct ConsoleAuthSheet: View {
    let title: String
    let loginURL: URL
    let cookieDomain: String
    let onSuccess: (ConsoleCookieResult) -> Void
    let onCancel: () -> Void

    @State private var isLoading = true
    @State private var hasError = false

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // WebView
            ConsoleAuthWebView(loginURL: loginURL, cookieDomain: cookieDomain) { result in
                onSuccess(result)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 680)
    }
}
