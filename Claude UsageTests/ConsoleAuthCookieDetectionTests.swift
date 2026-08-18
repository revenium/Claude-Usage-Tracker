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
        expires: Date? = nil
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
        ]
        if let expires = expires {
            properties[.expires] = expires
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

    func testUserAgentPresentsAsDesktopSafari() {
        let userAgent = ConsoleAuthWebView.safariUserAgent
        XCTAssertTrue(userAgent.contains("Safari/"))
        XCTAssertTrue(userAgent.contains("Version/"))
        XCTAssertFalse(userAgent.contains("Claude"))
    }
}
