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

    /// A fresh store makes every login sheet an isolated authentication attempt.
    /// This deliberately does not read or alter the user's browser profiles.
    /// Kept separate from view creation so its privacy properties are testable.
    static func makeWebsiteDataStore() -> WKWebsiteDataStore {
        .nonPersistent()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.makeWebsiteDataStore()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // The login page is a single-page app: after the user signs in, the
        // session cookie is set from an API response without a new main-frame
        // navigation, so didFinish alone never sees it. Observe the cookie
        // store directly so the cookie is detected whenever it lands. Capture
        // the baseline before navigation so a pre-existing cookie can never
        // complete this attempt.
        let cookieStore = config.websiteDataStore.httpCookieStore
        context.coordinator.beginAttempt(in: cookieStore) {
            webView.load(URLRequest(url: loginURL))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelAttempt()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cookieDomain: cookieDomain, onCookieFound: onCookieFound)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        nonisolated struct CookieFingerprint: Hashable {
            let name: String
            let value: String
            let domain: String
            let path: String
            let isSecure: Bool
            let expiresAt: Date?
        }

        let cookieDomain: String
        let onCookieFound: (ConsoleCookieResult) -> Void
        weak var observedCookieStore: WKHTTPCookieStore?
        private var baselineCookieFingerprints = Set<CookieFingerprint>()
        private var isAttemptReady = false
        private var isCompleted = false
        private var isCancelled = false

        init(cookieDomain: String, onCookieFound: @escaping (ConsoleCookieResult) -> Void) {
            self.cookieDomain = cookieDomain
            self.onCookieFound = onCookieFound
        }

        func cancelAttempt() {
            runOnMain { [weak self] in
                guard let self else { return }
                self.isCancelled = true
                self.stopObservingCookieStore()
                self.baselineCookieFingerprints.removeAll(keepingCapacity: false)
            }
        }

        private func stopObservingCookieStore() {
            observedCookieStore?.remove(self)
            observedCookieStore = nil
        }

        /// Establish the cookie baseline before loading the login page. This is
        /// important even with a non-persistent store because it keeps an
        /// injected/test store or a future implementation from auto-importing
        /// an existing credential.
        func beginAttempt(in cookieStore: WKHTTPCookieStore, load: @escaping () -> Void) {
            cookieStore.getAllCookies { [weak self] cookies in
                self?.runOnMain {
                    guard let self, !self.isCancelled, !self.isCompleted else { return }
                    self.baselineCookieFingerprints = Self.baselineCookieFingerprints(from: cookies)
                    self.isAttemptReady = true
                    self.observedCookieStore = cookieStore
                    cookieStore.add(self)
                    load()
                }
            }
        }

        // MARK: WKHTTPCookieStoreObserver

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            runOnMain { [weak self] in
                guard let self, self.isAttemptReady, !self.isCompleted, !self.isCancelled else { return }
                self.checkForSessionCookie(in: cookieStore)
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            runOnMain { [weak self] in
                guard let self, self.isAttemptReady, !self.isCompleted, !self.isCancelled else { return }
                self.checkForSessionCookie(in: webView.configuration.websiteDataStore.httpCookieStore)
            }
        }

        // MARK: WKUIDelegate

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Keep benign SSO popups in this isolated web view. Never turn a
            // request into a GET: doing so loses its semantics and can make an
            // untrusted popup URL executable in the login flow.
            let request = navigationAction.request
            if Self.isSafePopupRequest(request) {
                webView.load(request)
            }
            return nil
        }

        // MARK: Cookie detection

        /// Pure matcher, kept separate so it is unit-testable.
        nonisolated static func sessionCookieResult(
            in cookies: [HTTPCookie],
            matching cookieDomain: String,
            excluding baseline: Set<CookieFingerprint> = [],
            now: Date = Date()
        ) -> ConsoleCookieResult? {
            let normalizedTargetDomain = normalizedDomain(cookieDomain)
            guard !normalizedTargetDomain.isEmpty else { return nil }

            let candidates = cookies.filter { cookie in
                guard cookie.name == "sessionKey", cookie.isSecure else { return false }
                guard cookie.expiresDate.map({ $0 > now }) ?? true else { return false }
                guard domain(cookie.domain, matches: normalizedTargetDomain) else { return false }
                // The captured key is used for root API requests, so do not
                // accept a cookie that the browser itself scopes elsewhere.
                guard cookie.path == "/" else { return false }
                return !baseline.contains(cookieFingerprint(for: cookie))
            }

            // Cookie stores do not guarantee iteration order. Prefer an exact
            // domain, then a later expiry. The remaining fields make the
            // choice stable even for malformed duplicate sets.
            guard let cookie = candidates.sorted(by: {
                cookieSortOrder($0, $1, matching: normalizedTargetDomain)
            }).first else { return nil }
            return ConsoleCookieResult(sessionKey: cookie.value, expiryDate: cookie.expiresDate)
        }

        nonisolated static func baselineCookieFingerprints(from cookies: [HTTPCookie]) -> Set<CookieFingerprint> {
            Set(cookies.map(cookieFingerprint(for:)))
        }

        nonisolated static func cookieFingerprint(for cookie: HTTPCookie) -> CookieFingerprint {
            CookieFingerprint(
                name: cookie.name,
                value: cookie.value,
                domain: normalizedDomain(cookie.domain),
                path: cookie.path,
                isSecure: cookie.isSecure,
                expiresAt: cookie.expiresDate
            )
        }

        nonisolated static func isSafePopupRequest(_ request: URLRequest) -> Bool {
            guard request.url?.scheme?.lowercased() == "https" else { return false }
            return (request.httpMethod ?? "GET").uppercased() == "GET"
        }

        private func checkForSessionCookie(in cookieStore: WKHTTPCookieStore) {
            cookieStore.getAllCookies { [weak self] cookies in
                self?.runOnMain {
                    guard let self, self.isAttemptReady, !self.isCompleted, !self.isCancelled else { return }
                    guard let result = Self.sessionCookieResult(
                        in: cookies,
                        matching: self.cookieDomain,
                        excluding: self.baselineCookieFingerprints
                    ) else { return }
                    self.complete(with: result)
                }
            }
        }

        /// Claims the result exactly once and always invokes the UI callback on
        /// the main thread. Internal visibility lets focused tests exercise the
        /// race guard without requiring a live WKWebView.
        @discardableResult
        func complete(with result: ConsoleCookieResult) -> Bool {
            dispatchPrecondition(condition: .onQueue(.main))
            guard !isCompleted, !isCancelled else { return false }
            isCompleted = true
            stopObservingCookieStore()
            baselineCookieFingerprints.removeAll(keepingCapacity: false)
            onCookieFound(result)
            return true
        }

        private nonisolated static func normalizedDomain(_ domain: String) -> String {
            domain.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
        }

        private nonisolated static func domain(_ cookieDomain: String, matches targetDomain: String) -> Bool {
            let normalizedCookieDomain = normalizedDomain(cookieDomain)
            return normalizedCookieDomain == targetDomain
                || normalizedCookieDomain.hasSuffix("." + targetDomain)
        }

        private nonisolated static func cookieSortOrder(
            _ lhs: HTTPCookie,
            _ rhs: HTTPCookie,
            matching targetDomain: String
        ) -> Bool {
            let lhsDomain = normalizedDomain(lhs.domain)
            let rhsDomain = normalizedDomain(rhs.domain)
            let lhsIsExact = lhsDomain == targetDomain
            let rhsIsExact = rhsDomain == targetDomain
            if lhsIsExact != rhsIsExact { return lhsIsExact }
            if lhsDomain != rhsDomain { return lhsDomain < rhsDomain }
            if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }

            let lhsExpiry = lhs.expiresDate ?? .distantFuture
            let rhsExpiry = rhs.expiresDate ?? .distantFuture
            if lhsExpiry != rhsExpiry { return lhsExpiry > rhsExpiry }
            return lhs.value < rhs.value
        }

        private func runOnMain(_ work: @escaping () -> Void) {
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async(execute: work)
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
