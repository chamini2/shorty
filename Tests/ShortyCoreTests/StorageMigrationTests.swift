import XCTest
@testable import ShortyCore

final class StorageMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func database() throws -> ShortyDatabase {
        try ShortyDatabase(url: directory.appendingPathComponent("Shorty.sqlite"))
    }

    private func writeHistory(_ items: [ClipboardItem]) throws {
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("ClipboardHistory.json"))
    }

    private func writeRecents(_ paths: [String]) throws {
        try JSONEncoder().encode(paths).write(to: directory.appendingPathComponent("RecentFiles.json"))
    }

    private func writeCards(_ records: [String: LinkCardRecord]) throws {
        let cards = directory.appendingPathComponent("LinkCards", isDirectory: true)
        try FileManager.default.createDirectory(at: cards, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: cards.appendingPathComponent("Index.json"))
    }

    func testAnItemArrivesWithEverythingItCarried() throws {
        let asset = ClipboardAsset(
            fileName: "abc.png",
            type: "public.png",
            byteSize: 12,
            pixelWidth: 3,
            pixelHeight: 4
        )
        let original = ClipboardItem(
            plainText: "hello",
            rtfData: Data([0x01]),
            additionalRepresentations: [ClipboardRepresentation(type: "public.html", data: Data([0x02]))],
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            source: ClipboardSource(bundleID: "com.example", name: "Example"),
            image: asset,
            files: [ClipboardFileReference(path: "/tmp/a.txt")]
        )
        try writeHistory([original])

        let database = try self.database()
        XCTAssertEqual(StorageMigration.run(into: database), ["clipboard history"])

        let restored = try XCTUnwrap(ClipboardHistoryDatabase(database: database).recentItems(limit: 10).first)

        // The id is a hash of the content, so a faithful import rebuilds it.
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.plainText, original.plainText)
        XCTAssertEqual(restored.rtfData, original.rtfData)
        XCTAssertEqual(restored.additionalRepresentations, original.additionalRepresentations)
        XCTAssertEqual(restored.createdAt.timeIntervalSince1970, 1_000, accuracy: 0.001)
        XCTAssertEqual(restored.source?.bundleID, "com.example")
        XCTAssertEqual(restored.image, asset)
        XCTAssertEqual(restored.files, original.files)
    }

    func testTheOldFilesAreKeptRatherThanDeleted() throws {
        try writeHistory([ClipboardItem(plainText: "one")])

        _ = StorageMigration.run(into: try database())

        let json = directory.appendingPathComponent("ClipboardHistory.json")
        // A migration that goes wrong should cost a rename to undo.
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: json.appendingPathExtension(StorageMigration.suffix).path)
        )
    }

    func testRunningAgainDoesNothing() throws {
        try writeHistory([ClipboardItem(plainText: "one")])
        let database = try self.database()

        XCTAssertEqual(StorageMigration.run(into: database), ["clipboard history"])
        XCTAssertTrue(StorageMigration.run(into: database).isEmpty)
        XCTAssertEqual(try ClipboardHistoryDatabase(database: database).count(), 1)
    }

    func testCardsAndRecentsComeAcrossToo() throws {
        try writeCards([
            "https://example.com": LinkCardRecord(
                title: "Example",
                siteName: "example.com",
                fetchedAt: Date(timeIntervalSince1970: 5_000)
            ),
        ])
        try writeRecents(["/etc/hosts", "/usr/bin/env"])

        let database = try self.database()
        XCTAssertEqual(Set(StorageMigration.run(into: database)), ["link cards", "recent files"])

        let card = try LinkCardDatabase(database: database).record(for: "https://example.com")
        XCTAssertEqual(card?.title, "Example")

        // The list carried no times, only an order, which is preserved.
        let recents = try RecentFileDatabase(database: database).recent(limit: 10)
        XCTAssertEqual(recents, ["/etc/hosts", "/usr/bin/env"])
    }

    func testNothingToMigrateIsNotAFailure() throws {
        XCTAssertTrue(StorageMigration.run(into: try database()).isEmpty)
    }
}
