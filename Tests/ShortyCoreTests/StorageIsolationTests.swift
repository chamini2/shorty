import XCTest
@testable import ShortyCore

/// A store must only ever touch the directory its database lives in.
///
/// This is a regression test with a cost behind it: the migration and the
/// asset sweep both defaulted to the real Application Support folder
/// whatever database they were handed. A benchmark pointed at a scratch
/// database imported the live JSON files, renamed them, then swept every
/// clipboard image as unreferenced, because nothing in the scratch database
/// referred to any of them. Twenty-one pictures were lost.
final class StorageIsolationTests: XCTestCase {
    private var elsewhere: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        elsewhere = try makeDirectory("elsewhere")
        scratch = try makeDirectory("scratch")
    }

    override func tearDownWithError() throws {
        [elsewhere, scratch].forEach { try? FileManager.default.removeItem(at: $0) }
        try super.tearDownWithError()
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        return url
    }

    /// Stands in for a real Shorty folder: an image, and history to migrate.
    private func makeOccupiedDirectory() throws -> (image: URL, history: URL) {
        let assets = elsewhere.appendingPathComponent("ClipboardAssets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        let image = assets.appendingPathComponent("precious.png")
        try Data([0x01, 0x02, 0x03]).write(to: image)

        let history = elsewhere.appendingPathComponent("ClipboardHistory.json")
        try Data("[]".utf8).write(to: history)

        return (image, history)
    }

    private func scratchStore() throws -> ClipboardHistoryStore {
        ClipboardHistoryStore(
            database: try ShortyDatabase(url: scratch.appendingPathComponent("Shorty.sqlite")),
            maxStoredItems: 10
        )
    }

    func testAStoreLeavesAnotherDirectoryAlone() throws {
        let occupied = try makeOccupiedDirectory()

        let store = try scratchStore()
        store.addPlainText("hello")

        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.image.path), "swept another folder's images")
        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.history.path), "migrated another folder's history")
        XCTAssertEqual(store.recentItems(limit: 5).count, 1)
    }

    func testMigrationReadsOnlyBesideItsOwnDatabase() throws {
        _ = try makeOccupiedDirectory()
        let database = try ShortyDatabase(url: scratch.appendingPathComponent("Shorty.sqlite"))

        XCTAssertTrue(StorageMigration.run(into: database).isEmpty)
    }

    func testImagesAreKeptBesideTheDatabaseThatRefersToThem() throws {
        let store = try scratchStore()
        let image = Data(repeating: 0xAB, count: 32)
        let assets = ClipboardAssetStore(directory: scratch.appendingPathComponent("ClipboardAssets"))

        let asset = try XCTUnwrap(assets.store(data: image, type: "public.png", pixelWidth: 4, pixelHeight: 4))
        store.add(ClipboardItem(plainText: "shot", image: asset))

        // Still there after another store opens over the same database and
        // runs its sweep.
        _ = try scratchStore()

        XCTAssertEqual(assets.data(for: asset), image)
    }

    func testTheSweepStillClearsImagesNothingPointsAt() throws {
        let assets = ClipboardAssetStore(directory: scratch.appendingPathComponent("ClipboardAssets"))
        let orphan = try XCTUnwrap(
            assets.store(data: Data(repeating: 0x11, count: 16), type: "public.png", pixelWidth: 2, pixelHeight: 2)
        )

        // Written a while ago, so the grace period does not spare it.
        let url = assets.url(for: orphan)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: url.path
        )

        _ = try scratchStore()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
