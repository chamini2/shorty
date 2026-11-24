import XCTest
@testable import ShortyCore

final class ClipboardSettingsTests: XCTestCase {
    private func settings(_ yaml: String) throws -> ClipboardSettings {
        try ClipboardSettingsParser.parse(yaml: yaml)
    }

    func testLinkPreviewsAreOnWithoutAClipboardBlock() throws {
        XCTAssertTrue(ClipboardSettings.default.linkPreviewsEnabled)
        XCTAssertEqual(try settings("shortcuts: {}"), .default)
    }

    func testLinkPreviewsCanBeTurnedOff() throws {
        XCTAssertFalse(try settings("clipboard:\n  link-previews: false").linkPreviewsEnabled)
        XCTAssertFalse(try settings("clipboard:\n  link-previews: off").linkPreviewsEnabled)
        XCTAssertFalse(try settings("clipboard:\n  link-previews: no").linkPreviewsEnabled)
    }

    func testRejectsUnknownSettingAndNonBoolean() {
        XCTAssertThrowsError(try settings("clipboard:\n  link-preview: false")) { error in
            XCTAssertTrue(String(describing: error).contains("Unknown clipboard setting"))
        }

        XCTAssertThrowsError(try settings("clipboard:\n  link-previews: maybe")) { error in
            XCTAssertTrue(String(describing: error).contains("must be true or false"))
        }
    }

    func testOnlyRealLinksAreTreatedAsLinks() {
        XCTAssertEqual(
            ClipboardItemDetailBuilder.kind(for: ClipboardItem(plainText: "https://github.com/cmlad/shorty")),
            .link
        )
        XCTAssertEqual(
            ClipboardItemDetailBuilder.kind(for: ClipboardItem(plainText: "git@github.com:cmlad/shorty.git")),
            .text
        )
    }
}
