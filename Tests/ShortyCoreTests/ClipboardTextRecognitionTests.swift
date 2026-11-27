import AppKit
import XCTest
@testable import ShortyCore

final class ClipboardTextRecognitionTests: XCTestCase {
    private var directory: URL!
    private var database: ShortyDatabase!
    private var assets: ClipboardAssetStore!

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Recognition-\(UUID().uuidString)")
        database = try ShortyDatabase(url: directory.appendingPathComponent("Shorty.sqlite"))
        assets = ClipboardAssetStore(directory: directory.appendingPathComponent("ClipboardAssets"))
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// A picture of a sentence, drawn rather than fetched.
    private func picture(of text: String) throws -> Data {
        let size = NSSize(width: 420, height: 90)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.drawSwatch(in: NSRect(origin: .zero, size: size))
        (text as NSString).draw(at: NSPoint(x: 14, y: 30), withAttributes: [
            .font: NSFont.systemFont(ofSize: 28),
            .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func storedPicture(of text: String) throws -> ClipboardAsset {
        try XCTUnwrap(
            assets.store(data: try picture(of: text), type: "public.png", pixelWidth: 420, pixelHeight: 90)
        )
    }

    private func store(readsPictures: Bool = true) -> ClipboardHistoryStore {
        ClipboardHistoryStore(
            database: database,
            maxStoredItems: 10,
            assetStore: assets,
            readsPictures: readsPictures
        )
    }

    /// Recognition runs off the copy path, so the text arrives after the
    /// entry does.
    private func waitForText(in store: ClipboardHistoryStore) -> String? {
        let deadline = Date().addingTimeInterval(20)

        while Date() < deadline {
            if let text = store.recentItems(limit: 5).first?.ocrText {
                return text
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        return nil
    }

    func testTheWordsInAPictureAreRead() throws {
        let text = ClipboardTextRecognition.text(in: try picture(of: "deploy failed"))

        XCTAssertEqual(text?.localizedCaseInsensitiveContains("deploy failed"), true)
    }

    func testNothingLegibleReadsAsNothing() throws {
        // Drawn rather than merely sized: an image nothing has been drawn
        // into has no representation to ask for.
        let image = NSImage(size: NSSize(width: 40, height: 40))
        image.lockFocus()
        NSColor.white.drawSwatch(in: NSRect(x: 0, y: 0, width: 40, height: 40))
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let blank = try XCTUnwrap(representation.representation(using: .png, properties: [:]))

        XCTAssertNil(ClipboardTextRecognition.text(in: blank))
    }

    func testACopiedPictureGainsItsText() throws {
        let store = store()
        let item = ClipboardItem(plainText: "", image: try storedPicture(of: "deploy failed"))
        store.add(item)

        let text = try XCTUnwrap(waitForText(in: store), "the picture should be read")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("deploy"))

        let stored = try XCTUnwrap(store.recentItems(limit: 5).first)
        // The reading arrives after the row exists, so it must not be part
        // of what identifies the row.
        XCTAssertEqual(stored.id, item.id)
        // And it is a label, not something to paste.
        XCTAssertTrue(stored.plainText.isEmpty)
        XCTAssertNotNil(stored.image)
    }

    func testWhatThePictureSaysBecomesItsLabelAndSearchKey() throws {
        let store = store()
        store.add(ClipboardItem(plainText: "", image: try storedPicture(of: "deploy failed")))
        _ = waitForText(in: store)

        let stored = try XCTUnwrap(store.recentItems(limit: 5).first)
        XCTAssertTrue(stored.previewText.localizedCaseInsensitiveContains("deploy"))
        XCTAssertTrue(stored.searchableText.contains { $0.localizedCaseInsensitiveContains("deploy") })
    }

    func testPicturesGoUnreadWhenTheConfigSaysSo() throws {
        let store = store(readsPictures: false)
        store.add(ClipboardItem(plainText: "", image: try storedPicture(of: "deploy failed")))

        Thread.sleep(forTimeInterval: 1)

        XCTAssertNil(store.recentItems(limit: 5).first?.ocrText)
    }

    func testPicturesStoredBeforeAreReadToo() throws {
        let quiet = store(readsPictures: false)
        quiet.add(ClipboardItem(plainText: "", image: try storedPicture(of: "deploy failed")))

        let reading = store()
        reading.readPicturesAlreadyStored()

        XCTAssertNotNil(waitForText(in: reading), "a picture copied earlier should be read")
    }

    func testReadingSurvivesRecopying() throws {
        let store = store()
        let item = ClipboardItem(plainText: "", image: try storedPicture(of: "deploy failed"))
        store.add(item)
        _ = waitForText(in: store)

        // Copying the same picture again rewrites the row; the reading is
        // not something the pasteboard carries, so it must be kept.
        store.add(item)

        XCTAssertNotNil(store.recentItems(limit: 5).first?.ocrText)
    }
}
