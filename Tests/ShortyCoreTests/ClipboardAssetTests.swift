import AppKit
import XCTest
@testable import ShortyCore

final class ClipboardAssetTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardAssetStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = ClipboardAssetStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func pngData(width: Int, height: Int, color: NSColor = .red) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        color.drawSwatch(in: NSRect(x: 0, y: 0, width: width, height: height))
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    func testStoresImageAndReadsItBack() throws {
        let data = try pngData(width: 4, height: 2)
        let asset = try XCTUnwrap(store.store(data: data, type: "public.png", pixelWidth: 4, pixelHeight: 2))

        XCTAssertTrue(asset.fileName.hasSuffix(".png"))
        XCTAssertEqual(asset.byteSize, data.count)
        XCTAssertEqual(asset.pixelSizeLabel, "4 × 2")
        XCTAssertEqual(store.data(for: asset), data)
    }

    func testSameImageStoredTwiceReusesOneFile() throws {
        let data = try pngData(width: 4, height: 2)
        let first = try XCTUnwrap(store.store(data: data, type: "public.png", pixelWidth: 4, pixelHeight: 2))
        let second = try XCTUnwrap(store.store(data: data, type: "public.png", pixelWidth: 4, pixelHeight: 2))

        XCTAssertEqual(first.fileName, second.fileName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testSkipsImagesOverTheCap() throws {
        let data = Data(count: ClipboardConstants.maxStoredImageBytes + 1)

        XCTAssertNil(store.store(data: data, type: "public.png", pixelWidth: 1, pixelHeight: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRemoveOrphansKeepsReferencedFilesOnly() throws {
        let kept = try XCTUnwrap(
            store.store(data: try pngData(width: 4, height: 2), type: "public.png", pixelWidth: 4, pixelHeight: 2)
        )
        let dropped = try XCTUnwrap(
            store.store(data: try pngData(width: 8, height: 8, color: .blue), type: "public.png", pixelWidth: 8, pixelHeight: 8)
        )

        store.removeOrphans(keeping: [kept])

        XCTAssertNotNil(store.data(for: kept))
        XCTAssertNil(store.data(for: dropped))
    }

    func testStartupSweepSparesFreshlyStoredAssets() throws {
        let asset = try XCTUnwrap(
            store.store(data: try pngData(width: 4, height: 2), type: "public.png", pixelWidth: 4, pixelHeight: 2)
        )

        // An image is stored before the entry referencing it exists.
        _ = ClipboardHistoryStore(
            url: directory.appendingPathComponent("History.json"),
            maxStoredItems: 10,
            assetStore: store
        )

        XCTAssertNotNil(store.data(for: asset))
    }

    func testTrimmingHistoryDeletesTheOrphanedAsset() throws {
        let historyURL = directory.appendingPathComponent("History.json")
        let history = ClipboardHistoryStore(url: historyURL, maxStoredItems: 1, assetStore: store)

        let first = try XCTUnwrap(
            store.store(data: try pngData(width: 4, height: 2), type: "public.png", pixelWidth: 4, pixelHeight: 2)
        )
        let second = try XCTUnwrap(
            store.store(data: try pngData(width: 8, height: 8, color: .blue), type: "public.png", pixelWidth: 8, pixelHeight: 8)
        )

        history.add(ClipboardItem(plainText: "", image: first))
        history.add(ClipboardItem(plainText: "", image: second))

        XCTAssertEqual(history.recentItems().count, 1)
        XCTAssertNotNil(store.data(for: second))
        XCTAssertNil(store.data(for: first))
    }

    func testImageItemsWithDifferentPicturesGetDifferentIDs() throws {
        let first = try XCTUnwrap(
            store.store(data: try pngData(width: 4, height: 2), type: "public.png", pixelWidth: 4, pixelHeight: 2)
        )
        let second = try XCTUnwrap(
            store.store(data: try pngData(width: 8, height: 8, color: .blue), type: "public.png", pixelWidth: 8, pixelHeight: 8)
        )

        XCTAssertNotEqual(
            ClipboardItem(plainText: "", image: first).id,
            ClipboardItem(plainText: "", image: second).id
        )
    }

    func testPreviewTextDescribesImagesAndFiles() throws {
        let asset = ClipboardAsset(fileName: "a.png", type: "public.png", byteSize: 10, pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertEqual(ClipboardItem(plainText: "", image: asset).previewText, "Image 1920 × 1080")

        let item = ClipboardItem(plainText: "", files: [ClipboardFileReference(path: "/tmp/report.pdf")])
        XCTAssertEqual(item.previewText, "report.pdf")
        XCTAssertTrue(item.searchableText.contains("/tmp/report.pdf"))
    }

    func testRoundTripsImageAndFilesThroughJSON() throws {
        let item = ClipboardItem(
            plainText: "",
            source: ClipboardSource(bundleID: "com.apple.finder", name: "Finder"),
            image: ClipboardAsset(fileName: "a.png", type: "public.png", byteSize: 10, pixelWidth: 2, pixelHeight: 3),
            files: [ClipboardFileReference(path: "/tmp/report.pdf")]
        )

        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: JSONEncoder().encode(item))

        XCTAssertEqual(decoded.image, item.image)
        XCTAssertEqual(decoded.files, item.files)
        XCTAssertEqual(decoded.source, item.source)
        XCTAssertEqual(decoded.id, item.id)
    }

    func testDetailDescribesAnImage() {
        let asset = ClipboardAsset(fileName: "a.png", type: "public.png", byteSize: 2048, pixelWidth: 800, pixelHeight: 600)
        let detail = ClipboardItemDetailBuilder.detail(for: ClipboardItem(plainText: "", image: asset))

        XCTAssertEqual(detail.kind, .image)
        XCTAssertEqual(detail.image, asset)
        XCTAssertTrue(detail.rows.contains(ClipboardDetailRow(label: "Dimensions", value: "800 × 600")))
        XCTAssertTrue(detail.rows.contains { $0.label == "Size" })
    }

    func testDetailFlagsAMissingFile() {
        let item = ClipboardItem(plainText: "", files: [ClipboardFileReference(path: "/tmp/gone-\(UUID().uuidString).pdf")])
        let detail = ClipboardItemDetailBuilder.detail(for: item)

        XCTAssertEqual(detail.kind, .file)
        XCTAssertTrue(detail.rows.contains(ClipboardDetailRow(label: "State", value: "Missing")))
    }

    func testPasteWritesImageDataRatherThanAFileURL() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.shorty.tests.\(UUID().uuidString)"))
        let data = try pngData(width: 4, height: 2)
        let asset = try XCTUnwrap(store.store(data: data, type: "public.png", pixelWidth: 4, pixelHeight: 2))

        ClipboardPaster(pasteboard: pasteboard, assetStore: store)
            .copyToPasteboard(ClipboardItem(plainText: "", image: asset))

        XCTAssertEqual(pasteboard.data(forType: .png), data)
        XCTAssertNil(pasteboard.string(forType: .fileURL))
    }

    func testPasteWritesFileURLsForCopiedFiles() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.shorty.tests.\(UUID().uuidString)"))
        let fileURL = directory.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        ClipboardPaster(pasteboard: pasteboard, assetStore: store)
            .copyToPasteboard(ClipboardItem(plainText: "", files: [ClipboardFileReference(path: fileURL.path)]))

        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(urls?.map(\.lastPathComponent), ["note.txt"])
    }
}
