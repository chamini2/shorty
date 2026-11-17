import XCTest
@testable import ShortyCore

final class OpenGraphTests: XCTestCase {
    private let pageURL = URL(string: "https://example.com/post/1")!

    private func card(_ html: String) -> LinkCard {
        OpenGraphParser.card(html: html, from: pageURL)
    }

    func testReadsTheOpenGraphCard() {
        let result = card("""
        <html><head>
        <meta property="og:site_name" content="Example">
        <meta property="og:title" content="A post about clipboards">
        <meta property="og:description" content="Everything you copy, kept.">
        <meta property="og:image" content="https://cdn.example.com/card.png">
        </head><body>ignored</body></html>
        """)

        XCTAssertEqual(result.siteName, "Example")
        XCTAssertEqual(result.title, "A post about clipboards")
        XCTAssertEqual(result.summary, "Everything you copy, kept.")
        XCTAssertEqual(result.imageURL, URL(string: "https://cdn.example.com/card.png"))
        XCTAssertFalse(result.isEmpty)
    }

    func testOpenGraphWinsOverTwitterAndTheDocumentTitle() {
        let result = card("""
        <head>
        <title>Document title</title>
        <meta name="twitter:title" content="Twitter title">
        <meta property="og:title" content="Open Graph title">
        </head>
        """)

        XCTAssertEqual(result.title, "Open Graph title")
    }

    func testFallsBackToTwitterThenToTheDocument() {
        let twitter = card("""
        <head>
        <title>Document title</title>
        <meta name="twitter:title" content="Twitter title">
        <meta name="twitter:image" content="https://cdn.example.com/t.png">
        </head>
        """)

        XCTAssertEqual(twitter.title, "Twitter title")
        XCTAssertEqual(twitter.imageURL, URL(string: "https://cdn.example.com/t.png"))

        let plain = card("<head><title>Document title</title></head>")

        XCTAssertEqual(plain.title, "Document title")
        // Nothing said otherwise, so the host stands in for the site.
        XCTAssertEqual(plain.siteName, "example.com")
        XCTAssertNil(plain.imageURL)
    }

    func testResolvesAnImageWrittenRelativeToThePage() {
        let result = card(#"<meta property="og:image" content="/images/card.png">"#)

        XCTAssertEqual(result.imageURL, URL(string: "https://example.com/images/card.png"))
    }

    func testReadsQuotedAndUnquotedAttributesInEitherOrder() {
        let result = card("""
        <meta content='Single quoted' property='og:title'>
        <meta content=Bare property=og:site_name>
        """)

        XCTAssertEqual(result.title, "Single quoted")
        XCTAssertEqual(result.siteName, "Bare")
    }

    func testTurnsEscapesBackIntoText() {
        let result = card("""
        <meta property="og:title" content="Tom &amp; Jerry&#39;s &quot;big&quot; day">
        <meta property="og:description" content="Caf&#233; &mdash; open&hellip;">
        """)

        XCTAssertEqual(result.title, "Tom & Jerry's \"big\" day")
        XCTAssertEqual(result.summary, "Café — open…")
    }

    func testKeepsTheFirstOfRepeatedTags() {
        let result = card("""
        <meta property="og:image" content="https://cdn.example.com/first.png">
        <meta property="og:image" content="https://cdn.example.com/second.png">
        """)

        XCTAssertEqual(result.imageURL, URL(string: "https://cdn.example.com/first.png"))
    }

    func testAPageThatSaysNothingIsEmpty() {
        XCTAssertTrue(card("<html><body><p>Words on a page</p></body></html>").isEmpty)
        // A site name alone is not a card: it is only the address restated.
        XCTAssertEqual(card("<html></html>").siteName, "example.com")
    }

    func testIgnoresMetaTagsWithoutContent() {
        let result = card("""
        <meta property="og:title">
        <meta property="og:description" content="">
        <title>Document title</title>
        """)

        XCTAssertEqual(result.title, "Document title")
        XCTAssertNil(result.summary)
    }
}
