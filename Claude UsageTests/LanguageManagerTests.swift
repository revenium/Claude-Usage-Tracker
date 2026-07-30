import XCTest
@testable import Claude_Usage

final class LanguageManagerTests: XCTestCase {
    func testSimplifiedChineseAliasesCanonicalizeToAppleIdentifier() {
        for code in [
            "zh", "zh-cn", "zh-CN", "zh-ch", "zh-CH",
            "zh_hans", "zh-Hans"
        ] {
            XCTAssertEqual(
                LanguageManager.SupportedLanguage.from(code: code),
                .simplifiedChinese,
                "Expected \(code) to resolve to Simplified Chinese"
            )
        }
        XCTAssertEqual(
            LanguageManager.SupportedLanguage
                .simplifiedChinese.code,
            "zh-Hans"
        )
    }

    func testSupportedLanguageCodesMatchResourceCatalogs() {
        XCTAssertEqual(
            Set(
                LanguageManager.SupportedLanguage.allCases.map(
                    \.code
                )
            ),
            Set(
                UITestLaunchConfiguration.supportedLocales
            )
        )
    }
}
