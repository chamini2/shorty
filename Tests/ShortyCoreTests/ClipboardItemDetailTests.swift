import AppKit
import XCTest
@testable import ShortyCore

final class ClipboardItemDetailTests: XCTestCase {
    private func fixedFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    func testHistoryDetailListsSourceTypeSizeAndDate() {
        let copiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = ClipboardItem(
            plainText: "hello brave world",
            createdAt: copiedAt,
            updatedAt: copiedAt,
            source: ClipboardSource(bundleID: "com.google.Chrome", name: "Google Chrome")
        )

        let detail = ClipboardItemDetailBuilder.detail(for: item, dateFormatter: fixedFormatter())

        XCTAssertEqual(detail.body, "hello brave world")
        XCTAssertEqual(detail.kind, .text)
        XCTAssertEqual(detail.sourceBundleID, "com.google.Chrome")
        XCTAssertEqual(
            detail.rows,
            [
                ClipboardDetailRow(label: "Source", value: "Google Chrome"),
                ClipboardDetailRow(label: "Type", value: "Text"),
                ClipboardDetailRow(label: "Characters", value: "17"),
                ClipboardDetailRow(label: "Words", value: "3"),
                ClipboardDetailRow(label: "Copied", value: "2023-11-14 22:13"),
            ]
        )
    }

    func testHistoryDetailOmitsSourceRowWhenUnknown() {
        let item = ClipboardItem(plainText: "no source")
        let detail = ClipboardItemDetailBuilder.detail(for: item, dateFormatter: fixedFormatter())

        XCTAssertNil(detail.sourceBundleID)
        XCTAssertFalse(detail.rows.contains { $0.label == "Source" })
    }

    func testDetectsLinkKind() {
        XCTAssertTrue(ClipboardItemDetailBuilder.isLink("https://github.com/fal-ai/infra/pull/1"))
        XCTAssertTrue(ClipboardItemDetailBuilder.isLink("  http://example.com  "))
        XCTAssertFalse(ClipboardItemDetailBuilder.isLink("git@github.com:cmlad/shorty.git"))
        XCTAssertFalse(ClipboardItemDetailBuilder.isLink("see https://example.com for more"))
        XCTAssertFalse(ClipboardItemDetailBuilder.isLink("https://"))
        XCTAssertFalse(ClipboardItemDetailBuilder.isLink(""))
    }

    func testRichTextKindWhenRTFIsPresent() {
        let item = ClipboardItem(plainText: "styled", rtfData: Data([0x01]))
        XCTAssertEqual(ClipboardItemDetailBuilder.kind(for: item), .richText)
    }

    func testImageKindWinsOverOtherRepresentations() {
        let item = ClipboardItem(
            plainText: "https://example.com/cat.png",
            rtfData: Data([0x01]),
            additionalRepresentations: [ClipboardRepresentation(type: "public.png", data: Data([0x02]))]
        )

        XCTAssertEqual(ClipboardItemDetailBuilder.kind(for: item), .image)
    }

    func testSnippetDetailUsesGroupAndContent() {
        let entry = ClipboardPickerEntry.snippet(
            groupTitle: "Work",
            snippet: Snippet(title: "Greeting", content: "Hello from Shorty.")
        )

        let detail = ClipboardItemDetailBuilder.detail(for: entry, dateFormatter: fixedFormatter())

        XCTAssertEqual(detail?.body, "Hello from Shorty.")
        XCTAssertEqual(detail?.kind, .snippet)
        XCTAssertEqual(
            detail?.rows,
            [
                ClipboardDetailRow(label: "Group", value: "Work"),
                ClipboardDetailRow(label: "Type", value: "Snippet"),
                ClipboardDetailRow(label: "Characters", value: "18"),
                ClipboardDetailRow(label: "Words", value: "3"),
            ]
        )
    }

    func testFolderDetailCountsPasteableEntries() {
        let folder = ClipboardPickerFolder(
            id: "snippets:Work",
            title: "Work",
            kind: .snippets,
            entries: [
                .header("Work"),
                .snippet(groupTitle: "Work", snippet: Snippet(title: "A", content: "a")),
                .snippet(groupTitle: "Work", snippet: Snippet(title: "B", content: "b")),
            ]
        )

        let detail = ClipboardItemDetailBuilder.detail(for: .folder(folder), dateFormatter: fixedFormatter())

        XCTAssertEqual(detail?.kind, .folder)
        XCTAssertEqual(detail?.rows.last, ClipboardDetailRow(label: "Items", value: "2"))
    }

    func testNoDetailForNonContentEntries() {
        XCTAssertNil(ClipboardItemDetailBuilder.detail(for: .header("History")))
        XCTAssertNil(ClipboardItemDetailBuilder.detail(for: .back("..")))
        XCTAssertNil(ClipboardItemDetailBuilder.detail(for: .empty("No matches")))
    }

    func testSourceCaptureSkipsShortyItself() {
        XCTAssertNil(
            ClipboardSource.frontmostApplication(
                workspace: .shared,
                ownPID: NSRunningApplication.current.processIdentifier
            )
        )
    }
}
