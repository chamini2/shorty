import XCTest
@testable import ShortyCore

final class ScratchPadTests: XCTestCase {
    private var directory: URL!
    private var database: ShortyDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScratchPad-\(UUID().uuidString)")
        database = try ShortyDatabase(url: directory.appendingPathComponent("Shorty.sqlite"))
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testAnUntouchedPadIsEmpty() {
        XCTAssertEqual(ScratchPadStore(database: database).text(), "")
    }

    func testThePadIsWhereItWasLeft() throws {
        ScratchPadStore(database: database).setText("half an email")

        let reopened = ScratchPadStore(
            database: try ShortyDatabase(url: directory.appendingPathComponent("Shorty.sqlite"))
        )

        XCTAssertEqual(reopened.text(), "half an email")
    }

    func testClearingThePadLeavesNoRowBehind() throws {
        let pad = ScratchPadStore(database: database)
        pad.setText("something")
        pad.setText("")

        XCTAssertEqual(pad.text(), "")
        XCTAssertNil(database.metaValue(for: ScratchPadStore.metaKey))
    }

    func testRewritingThePadReplacesIt() {
        let pad = ScratchPadStore(database: database)
        pad.setText("first")
        pad.setText("second")

        XCTAssertEqual(pad.text(), "second")
    }

    func testTheBoxCanReachThePadWithoutAHotkey() throws {
        let entries = CommandCatalog.rootEntries(query: "scratch")
        let entry = try XCTUnwrap(entries.first { $0.id == "scratch-pad" })

        XCTAssertEqual(entry.destination, .view(.scratchPad))
    }

    func testThePadHasAKeyOfItsOwn() throws {
        let bindings = try HotKeyBindingsParser.parse(yaml: """
        hotkeys:
          scratch-pad: cmd+ctrl+p
        """)

        XCTAssertEqual(bindings.scratchPad, try KeyCombo.parse("cmd+ctrl+p"))
        // And the rest keep theirs.
        XCTAssertEqual(bindings.commandBox, DefaultHotKeys.commandBox)
    }
}
