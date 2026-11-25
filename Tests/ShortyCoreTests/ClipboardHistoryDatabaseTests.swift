import XCTest
@testable import ShortyCore

/// The store's own behaviour, now that rows rather than a rewritten file
/// stand behind it.
final class ClipboardHistoryDatabaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("History-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func store(limit: Int = 100) throws -> ClipboardHistoryStore {
        ClipboardHistoryStore(
            database: try ShortyDatabase(url: directory.appendingPathComponent("Shorty.sqlite")),
            maxStoredItems: limit
        )
    }

    func testEntriesComeBackNewestFirst() throws {
        let store = try store()
        store.addPlainText("one")
        store.addPlainText("two")

        XCTAssertEqual(store.recentItems(limit: 10).map(\.plainText), ["two", "one"])
    }

    func testCopyingSomethingTwiceKeepsOneEntry() throws {
        let store = try store()
        store.add(ClipboardItem(plainText: "same", source: ClipboardSource(bundleID: "com.a", name: "A")))
        let first = try XCTUnwrap(store.recentItems(limit: 1).first)

        store.add(ClipboardItem(plainText: "same"))
        let entries = store.recentItems(limit: 10)

        XCTAssertEqual(entries.count, 1)
        // It keeps the day it first arrived, and the app that owned up to it.
        XCTAssertEqual(entries[0].createdAt.timeIntervalSince1970, first.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(entries[0].source?.bundleID, "com.a")
        XCTAssertGreaterThanOrEqual(entries[0].updatedAt, first.updatedAt)
    }

    func testTheOldestGoWhenTheLimitIsReached() throws {
        let store = try store(limit: 2)
        store.addPlainText("one")
        store.addPlainText("two")
        store.addPlainText("three")

        XCTAssertEqual(store.recentItems(limit: 10).map(\.plainText), ["three", "two"])
    }

    func testLoweringTheLimitTrimsAtOnce() throws {
        let store = try store(limit: 10)
        ["one", "two", "three"].forEach(store.addPlainText)

        store.setMaximumItems(1)

        XCTAssertEqual(store.recentItems(limit: 10).map(\.plainText), ["three"])
    }

    func testRemovingReportsWhetherAnythingWent() throws {
        let store = try store()
        store.addPlainText("one")
        let entry = try XCTUnwrap(store.recentItems(limit: 1).first)

        XCTAssertTrue(store.remove(id: entry.id))
        XCTAssertFalse(store.remove(id: entry.id))
        XCTAssertTrue(store.recentItems(limit: 10).isEmpty)
    }

    func testEverythingAnEntryCarriesSurvivesAReopen() throws {
        let asset = ClipboardAsset(fileName: "a.png", type: "public.png", byteSize: 9, pixelWidth: 2, pixelHeight: 3)
        let original = ClipboardItem(
            plainText: "rich",
            rtfData: Data([0x01]),
            rtfdData: Data([0x02]),
            additionalRepresentations: [ClipboardRepresentation(type: "public.html", data: Data([0x03]))],
            source: ClipboardSource(bundleID: "com.example", name: "Example"),
            image: asset,
            files: [ClipboardFileReference(path: "/tmp/a.txt"), ClipboardFileReference(path: "/tmp/b.txt")]
        )

        try store().add(original)
        let restored = try XCTUnwrap(try store().recentItems(limit: 1).first)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.rtfData, original.rtfData)
        XCTAssertEqual(restored.rtfdData, original.rtfdData)
        XCTAssertEqual(restored.additionalRepresentations, original.additionalRepresentations)
        XCTAssertEqual(restored.source?.name, "Example")
        XCTAssertEqual(restored.image, asset)
        // Files keep their order, which is the order they were copied in.
        XCTAssertEqual(restored.files.map(\.path), ["/tmp/a.txt", "/tmp/b.txt"])
    }

    func testTheListsOfAnEntryAreReplacedRatherThanRepeated() throws {
        let store = try store()
        let item = ClipboardItem(
            plainText: "same",
            additionalRepresentations: [ClipboardRepresentation(type: "public.html", data: Data([0x01]))],
            files: [ClipboardFileReference(path: "/tmp/a.txt")]
        )

        store.add(item)
        store.add(item)

        let restored = try XCTUnwrap(store.recentItems(limit: 1).first)
        XCTAssertEqual(restored.additionalRepresentations.count, 1)
        XCTAssertEqual(restored.files.count, 1)
    }
}
