import XCTest
@testable import ShortyCore

final class LinkCardStoreTests: XCTestCase {
    private var directory: URL!
    private let pageURL = URL(string: "https://example.com/post")!
    private let image = Data(repeating: 0xAB, count: 2048)

    private var card: LinkCard {
        LinkCard(url: pageURL, title: "A post", summary: "Words", siteName: "Example")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LinkCardStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private func store() -> LinkCardStore {
        LinkCardStore(directory: directory)
    }

    func testACardOutlivesTheProcessThatFetchedIt() throws {
        store().save(card, imageData: image, for: pageURL)

        // A second store is what the next launch of the app sees.
        let reopened = store()
        let record = try XCTUnwrap(reopened.record(for: pageURL))

        XCTAssertEqual(record.title, "A post")
        XCTAssertEqual(record.summary, "Words")
        XCTAssertEqual(record.siteName, "Example")
        XCTAssertEqual(reopened.imageData(for: record), image)
        XCTAssertFalse(record.failed)
    }

    func testAFragmentIsTheSamePage() {
        store().save(card, imageData: image, for: pageURL)

        XCTAssertNotNil(store().record(for: URL(string: "https://example.com/post#reply")!))
    }

    func testACardGoesStaleAfterAWeek() {
        let keeper = store()
        keeper.save(card, imageData: image, for: pageURL, now: Date().addingTimeInterval(-8 * 24 * 60 * 60))

        XCTAssertNil(store().record(for: pageURL))
    }

    func testAFailureIsRememberedButNotForLong() {
        let keeper = store()
        keeper.save(nil, imageData: nil, for: pageURL)

        XCTAssertEqual(keeper.record(for: pageURL)?.failed, true)
        XCTAssertNil(keeper.record(for: pageURL, now: Date().addingTimeInterval(2 * 24 * 60 * 60)))
    }

    func testPicturesNothingPointsAtAreSweptUp() throws {
        let keeper = store()
        keeper.save(card, imageData: image, for: pageURL, now: Date().addingTimeInterval(-8 * 24 * 60 * 60))

        // Saving anything prunes what has gone stale, pictures included.
        keeper.save(nil, imageData: nil, for: URL(string: "https://example.com/other")!)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)

        XCTAssertTrue(files.filter { $0.hasSuffix(".img") }.isEmpty)
    }
}
