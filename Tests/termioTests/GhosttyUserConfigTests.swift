import XCTest
@testable import termio

final class GhosttyUserConfigTests: XCTestCase {
    private func parsed(_ text: String) -> GhosttyUserConfig {
        var config = GhosttyUserConfig()
        config.merge(parsing: text)
        return config
    }

    func testParsesFontFamilyChainInOrder() {
        let config = parsed("""
        font-family = Berkeley Mono
        font-family = Sarasa Mono SC
        """)
        XCTAssertEqual(config.fontFamilies, ["Berkeley Mono", "Sarasa Mono SC"])
    }

    func testEmptyFontFamilyResetsChain() {
        let config = parsed("""
        font-family = Menlo
        font-family =
        font-family = JetBrains Mono
        """)
        XCTAssertEqual(config.fontFamilies, ["JetBrains Mono"])
    }

    func testStripsQuotesAndWhitespace() {
        let config = parsed("  font-family   =  \"JetBrains Mono\"  ")
        XCTAssertEqual(config.fontFamilies, ["JetBrains Mono"])
    }

    func testSkipsCommentsAndUnknownKeys() {
        let config = parsed("""
        # font-family = Commented Out
        window-decoration = false
        not a config line
        font-size = 15
        """)
        XCTAssertEqual(config.fontFamilies, [])
        XCTAssertEqual(config.fontSize, 15)
    }

    func testLastValueWinsForSingleValueKeys() {
        let config = parsed("""
        font-size = 12
        font-size = 16
        theme = Dracula
        theme = Nord
        """)
        XCTAssertEqual(config.fontSize, 16)
        XCTAssertEqual(config.theme, "Nord")
    }

    func testBareThemeAppliesToBothAppearances() {
        let names = parsed("theme = Dracula").themeNames
        XCTAssertEqual(names.light, "Dracula")
        XCTAssertEqual(names.dark, "Dracula")
    }

    func testSplitThemeFormParsesPerAppearance() {
        let names = parsed("theme = light:Solarized Light, dark:Nord").themeNames
        XCTAssertEqual(names.light, "Solarized Light")
        XCTAssertEqual(names.dark, "Nord")
    }

    func testDuplicateFontFamiliesCollapse() {
        var config = parsed("font-family = Berkeley Mono")
        config.merge(parsing: "font-family = Berkeley Mono")
        XCTAssertEqual(config.fontFamilies, ["Berkeley Mono"])
    }

    func testMergeAcrossFilesAccumulatesFamiliesAndOverridesScalars() {
        var config = parsed("""
        font-family = Menlo
        font-size = 12
        """)
        config.merge(parsing: """
        font-family = Sarasa Mono SC
        font-size = 14
        """)
        XCTAssertEqual(config.fontFamilies, ["Menlo", "Sarasa Mono SC"])
        XCTAssertEqual(config.fontSize, 14)
    }

    func testMissingFilesYieldEmptyConfig() {
        let config = GhosttyUserConfig.load(
            home: URL(fileURLWithPath: "/nonexistent-home-for-test"),
            environment: [:]
        )
        XCTAssertTrue(config.isEmpty)
    }
}
