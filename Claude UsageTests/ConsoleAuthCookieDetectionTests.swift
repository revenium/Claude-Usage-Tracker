//
//  ConsoleAuthCookieDetectionTests.swift
//  Claude Usage Tests
//
//  Created on 2026-08-18.
//

import XCTest
@testable import Claude_Usage

final class ConsoleAuthCookieDetectionTests: XCTestCase {

    private func makeCookie(
        name: String,
        value: String,
        domain: String,
        expires: Date? = nil,
        secure: Bool = true,
        path: String = "/"
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if let expires = expires {
            properties[.expires] = expires
        }
        if secure {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)!
    }

    func testFindsSessionKeyCookieOnMatchingDomain() {
        let expiry = Date(timeIntervalSinceNow: 86400)
        let cookies = [
            makeCookie(name: "other", value: "x", domain: ".claude.ai"),
            makeCookie(name: "sessionKey", value: "sk-ant-sid01-abc", domain: ".claude.ai", expires: expiry),
        ]

        let result = ConsoleAuthWebView.Coordinator.sessionCookieResult(
            in: cookies, matching: "claude.ai"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sessionKey, "sk-ant-sid01-abc")
        XCTAssertNotNil(result?.expiryDate)
    }

    func testIgnoresSessionKeyCookieFromOtherDomains() {
        let cookies = [
            makeCookie(name: "sessionKey", value: "nope", domain: ".example.com")
        ]

        let result = ConsoleAuthWebView.Coordinator.sessionCookieResult(
            in: cookies, matching: "claude.ai"
        )

        XCTAssertNil(result)
    }

    func testIgnoresNonSessionCookies() {
        let cookies = [
            makeCookie(name: "cf_clearance", value: "x", domain: ".claude.ai"),
            makeCookie(name: "ajs_anonymous_id", value: "y", domain: ".claude.ai"),
        ]

        let result = ConsoleAuthWebView.Coordinator.sessionCookieResult(
            in: cookies, matching: "claude.ai"
        )

        XCTAssertNil(result)
    }

    func testLoginUsesFreshNonPersistentDataStores() {
        let first = ConsoleAuthWebView.makeWebsiteDataStore()
        let second = ConsoleAuthWebView.makeWebsiteDataStore()

        XCTAssertFalse(first.isPersistent)
        XCTAssertFalse(second.isPersistent)
        XCTAssertFalse(first === second)
    }

    func testRejectsLookalikeCookieDomainButAcceptsSubdomainBoundary() {
        let cookies = [
            makeCookie(name: "sessionKey", value: "lookalike", domain: "notclaude.ai"),
            makeCookie(name: "sessionKey", value: "suffixAttack", domain: "claude.ai.attacker.example"),
            makeCookie(name: "sessionKey", value: "subdomain", domain: "console.claude.ai"),
        ]

        let result = ConsoleAuthWebView.Coordinator.sessionCookieResult(
            in: cookies, matching: "claude.ai"
        )

        XCTAssertEqual(result?.sessionKey, "subdomain")
    }

    func testRejectsInsecureAndExpiredSessionCookies() {
        let cookies = [
            makeCookie(name: "sessionKey", value: "insecure", domain: ".claude.ai", secure: false),
            makeCookie(
                name: "sessionKey",
                value: "expired",
                domain: ".claude.ai",
                expires: Date(timeIntervalSinceNow: -60)
            ),
        ]

        XCTAssertNil(ConsoleAuthWebView.Coordinator.sessionCookieResult(in: cookies, matching: "claude.ai"))
    }

    func testSelectsDuplicateCookiesDeterministically() {
        let cookies = [
            makeCookie(name: "sessionKey", value: "subdomain", domain: "console.claude.ai", path: "/"),
            makeCookie(name: "sessionKey", value: "exact", domain: ".claude.ai", path: "/"),
        ]

        let result = ConsoleAuthWebView.Coordinator.sessionCookieResult(
            in: cookies, matching: "claude.ai"
        )

        XCTAssertEqual(result?.sessionKey, "exact")
    }

    func testRejectsNonRootPathSessionCookie() {
        let cookie = makeCookie(name: "sessionKey", value: "scoped", domain: ".claude.ai", path: "/settings")

        XCTAssertNil(ConsoleAuthWebView.Coordinator.sessionCookieResult(in: [cookie], matching: "claude.ai"))
    }

    func testDoesNotCompleteFromBaselineCookie() {
        let stale = makeCookie(name: "sessionKey", value: "stale", domain: ".claude.ai")
        let fresh = makeCookie(name: "sessionKey", value: "fresh", domain: ".claude.ai")
        let baseline = ConsoleAuthWebView.Coordinator.baselineCookieFingerprints(from: [stale])

        let result = ConsoleAuthWebView.Coordinator.sessionCookieResult(
            in: [stale, fresh],
            matching: "claude.ai",
            excluding: baseline
        )

        XCTAssertEqual(result?.sessionKey, "fresh")
    }

    func testCompletionCallbackRunsOnlyOnce() {
        var completionCount = 0
        let coordinator = ConsoleAuthWebView.Coordinator(cookieDomain: "claude.ai") { _ in
            completionCount += 1
        }
        let result = ConsoleCookieResult(sessionKey: "sk-ant-sid01-abc", expiryDate: nil)

        XCTAssertTrue(coordinator.complete(with: result))
        XCTAssertFalse(coordinator.complete(with: result))
        XCTAssertEqual(completionCount, 1)
    }

    func testAllowsOnlyHTTPSGetPopupRequests() {
        var httpsGet = URLRequest(url: URL(string: "https://accounts.example.com/login")!)
        httpsGet.httpMethod = "GET"
        var httpsPost = httpsGet
        httpsPost.httpMethod = "POST"
        let httpGet = URLRequest(url: URL(string: "http://accounts.example.com/login")!)

        XCTAssertTrue(ConsoleAuthWebView.Coordinator.isSafePopupRequest(httpsGet))
        XCTAssertFalse(ConsoleAuthWebView.Coordinator.isSafePopupRequest(httpsPost))
        XCTAssertFalse(ConsoleAuthWebView.Coordinator.isSafePopupRequest(httpGet))
    }
}
