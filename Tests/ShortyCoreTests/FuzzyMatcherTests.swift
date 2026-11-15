import XCTest
@testable import ShortyCore

final class FuzzyMatcherTests: XCTestCase {
    func testMatchesExactPrefixAndSubsequence() {
        XCTAssertNotNil(FuzzyMatcher.score("maximize", in: "Maximize"))
        XCTAssertNotNil(FuzzyMatcher.score("maxi", in: "Maximize"))
        XCTAssertNotNil(FuzzyMatcher.score("sf", in: "San Francisco"))
    }

    func testRejectsWrongOrderAndMissingLetters() {
        XCTAssertNil(FuzzyMatcher.score("zyx", in: "xyz"))
        XCTAssertNil(FuzzyMatcher.score("maxq", in: "Maximize"))
        XCTAssertNil(FuzzyMatcher.score("abc", in: ""))
    }

    func testFoldsCaseAndAccents() {
        XCTAssertNotNil(FuzzyMatcher.score("UTC", in: "utc"))
        XCTAssertNotNil(FuzzyMatcher.score("tokyo", in: "Tōkyō"))
        XCTAssertNotNil(FuzzyMatcher.score("sao paulo", in: "São Paulo"))
    }

    func testRanksTheDeliberateMatchHigher() throws {
        let exact = try XCTUnwrap(FuzzyMatcher.score("time", in: "Time"))
        let prefix = try XCTUnwrap(FuzzyMatcher.score("tim", in: "Time"))
        let longer = try XCTUnwrap(FuzzyMatcher.score("time", in: "Time Zone Settings"))

        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(exact, longer)

        // Initials at word starts beat the same letters scattered mid-word.
        let initials = try XCTUnwrap(FuzzyMatcher.score("sf", in: "San Francisco"))
        let scattered = try XCTUnwrap(FuzzyMatcher.score("sf", in: "Snippets for"))
        XCTAssertGreaterThan(initials, scattered)
    }

    func testEmptyQueryMatchesAnything() {
        XCTAssertEqual(FuzzyMatcher.score("", in: "Anything"), 0)
    }

    func testBestScoreTakesTheStrongestName() throws {
        let best = try XCTUnwrap(FuzzyMatcher.bestScore("clip", in: ["Window", "clipboard", "paste"]))
        let direct = try XCTUnwrap(FuzzyMatcher.score("clip", in: "clipboard"))

        XCTAssertEqual(best, direct)
    }
}
