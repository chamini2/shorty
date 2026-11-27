import XCTest
@testable import ShortyCore

final class ClipboardPickerSearchTests: XCTestCase {
    func testRootEntriesListHistoryFlatAndSnippetsAsFolders() throws {
        let history = (1...45).map { ClipboardItem(plainText: "History \($0)") }
        let groups = [
            SnippetGroup(
                title: "Work",
                snippets: [Snippet(title: "Greeting", content: "Hello")]
            ),
            SnippetGroup(
                title: "Personal",
                snippets: [Snippet(title: "Address", content: "123 Main")]
            ),
        ]

        let entries = ClipboardPickerSearch.rootEntries(
            history: history,
            snippetGroups: groups,
            query: "",
            mode: .all
        )

        XCTAssertEqual(entries[0], .header("Snippets"))
        XCTAssertEqual(entries[1].title, "Work")
        XCTAssertEqual(entries[2].title, "Personal")
        XCTAssertEqual(entries[3], .header("History"))
        XCTAssertEqual(entries[4...48].compactMap(\.pasteResult), history.map { .history($0) })

        // Only snippet groups are folders now; history is one scrollable list.
        XCTAssertTrue(entries[4...48].allSatisfy { $0.folder == nil })

        guard case let .folder(workFolder) = entries[1] else {
            return XCTFail("Expected snippet folder")
        }

        XCTAssertEqual(workFolder.entries, [
            .snippet(groupTitle: "Work", snippet: groups[0].snippets[0]),
        ])
    }

    func testHistoryIsCappedAtTheVisibleLimit() {
        let history = (1...(ClipboardConstants.maxVisibleItems + 30))
            .map { ClipboardItem(plainText: "History \($0)") }

        let entries = ClipboardPickerSearch.rootEntries(
            history: history,
            snippetGroups: [],
            query: "",
            mode: .all
        )

        XCTAssertEqual(entries.compactMap(\.pasteResult).count, ClipboardConstants.maxVisibleItems)
    }

    func testRootSearchFlattensMatchingDescendants() throws {
        let history = (1...25).map { index in
            ClipboardItem(plainText: index == 25 ? "Deep needle" : "History \(index)")
        }
        let groups = [
            SnippetGroup(
                title: "Work",
                snippets: [Snippet(title: "Greeting", content: "Hello needle")]
            ),
        ]

        let entries = ClipboardPickerSearch.rootEntries(
            history: history,
            snippetGroups: groups,
            query: "needle",
            mode: .all
        )

        // Snippets lead here as they do unfiltered: one order, searched or not.
        XCTAssertEqual(entries.map(\.title), ["Snippets", "Greeting", "History", "Deep needle"])
        XCTAssertEqual(entries[1].pasteResult, .snippet(groupTitle: "Work", snippet: groups[0].snippets[0]))
        XCTAssertEqual(entries[3].pasteResult, .history(history[24]))
    }

    func testRootSearchKeepsMatchingFoldersOpenable() throws {
        let history = (1...25).map { ClipboardItem(plainText: "History \($0)") }
        let groups = [
            SnippetGroup(
                title: "Infrastructure",
                snippets: [Snippet(title: "Deploy", content: "ship it")]
            ),
        ]

        let entries = ClipboardPickerSearch.rootEntries(
            history: history,
            snippetGroups: groups,
            query: "infra",
            mode: .all
        )

        XCTAssertEqual(entries.map(\.title), ["Snippets", "Infrastructure"])
        XCTAssertNotNil(entries[1].folder)
    }

    func testHistoryTitlesUsePickerCutoffInsteadOfMenuCutoff() throws {
        let longText = String(repeating: "a", count: ClipboardConstants.maxMenuItemTitleLength + 20)

        XCTAssertEqual(try onlyHistoryEntry(for: longText).title, longText)
    }

    func testHistoryPresentationSeparatesLineCountMarker() throws {
        let entry = try onlyHistoryEntry(for: "First line\nSecond line\nThird line")

        XCTAssertEqual(entry.presentation.title, "First line")
        XCTAssertEqual(entry.presentation.trailingLineCountLabel, "+2")
        XCTAssertEqual(entry.title, "First line")
    }

    func testHistoryPresentationOmitsLineCountMarkerForSingleLineItems() throws {
        let entry = try onlyHistoryEntry(for: "Only line")

        XCTAssertEqual(entry.presentation.title, "Only line")
        XCTAssertNil(entry.presentation.trailingLineCountLabel)
    }

    func testHistoryPresentationUsesFirstNonBlankLineAndCountsFollowingLines() throws {
        let entry = try onlyHistoryEntry(for: "\n\n  First content line\nSecond line")

        XCTAssertEqual(entry.presentation.title, "  First content line")
        XCTAssertEqual(entry.presentation.trailingLineCountLabel, "+1")
    }

    func testHistoryPresentationCountsCRLFAsSingleLineBreak() throws {
        let entry = try onlyHistoryEntry(for: "First line\r\nSecond line\r\nThird line")

        XCTAssertEqual(entry.presentation.title, "First line")
        XCTAssertEqual(entry.presentation.trailingLineCountLabel, "+2")
    }

    func testPinnedItemsAppearInOwnSectionAboveHistory() {
        let olderPin = ClipboardItem(
            plainText: "Older pin",
            pinnedAt: Date(timeIntervalSince1970: 100)
        )
        let newerPin = ClipboardItem(
            plainText: "Newer pin",
            pinnedAt: Date(timeIntervalSince1970: 200)
        )
        let unpinned = ClipboardItem(plainText: "Regular copy")

        let entries = ClipboardPickerSearch.rootEntries(
            history: [olderPin, unpinned, newerPin],
            snippetGroups: [],
            query: "",
            mode: .all
        )

        XCTAssertEqual(entries.map(\.title), ["Pinned", "Newer pin", "Older pin", "History", "Regular copy"])

        let filtered = ClipboardPickerSearch.rootEntries(
            history: [olderPin, unpinned, newerPin],
            snippetGroups: [],
            query: "pin",
            mode: .all
        )

        XCTAssertEqual(filtered.map(\.title), ["Pinned", "Newer pin", "Older pin"])
    }

    private func onlyHistoryEntry(for text: String) throws -> ClipboardPickerEntry {
        let entries = ClipboardPickerSearch.rootEntries(
            history: [ClipboardItem(plainText: text)],
            snippetGroups: [],
            query: "",
            mode: .all
        )

        return try XCTUnwrap(entries.first { $0.pasteResult != nil })
    }

    func testActivationModeUsesCommandForCopyOnly() {
        XCTAssertEqual(
            ClipboardPickerActivationMode.fromModifiers(command: true, shift: false),
            .copyOnly
        )
    }

    func testActivationModeUsesOptionForPlainText() {
        XCTAssertEqual(
            ClipboardPickerActivationMode.fromModifiers(command: false, shift: false, option: true),
            .plainText
        )
    }

    func testActivationModeGivesCommandPrecedenceOverOption() {
        XCTAssertEqual(
            ClipboardPickerActivationMode.fromModifiers(command: true, shift: false, option: true),
            .copyOnly
        )
    }

    func testActivationModeUsesStandardWithoutModifiers() {
        XCTAssertEqual(
            ClipboardPickerActivationMode.fromModifiers(command: false, shift: false),
            .standard
        )
    }

    func testActivationModeUsesShiftForJoinedLines() {
        XCTAssertEqual(
            ClipboardPickerActivationMode.fromModifiers(command: false, shift: true),
            .joinedLines
        )
    }

    func testActivationModeGivesShiftPrecedenceOverCommand() {
        XCTAssertEqual(
            ClipboardPickerActivationMode.fromModifiers(command: true, shift: true),
            .joinedLines
        )
    }

    func testFolderSearchOnlyFiltersFolderEntries() throws {
        let folder = ClipboardPickerFolder(
            id: "snippets:Work",
            title: "Work",
            kind: .snippets,
            entries: [
                .snippet(groupTitle: "Work", snippet: Snippet(title: "Greeting", content: "Hello")),
                .snippet(groupTitle: "Work", snippet: Snippet(title: "Incident", content: "Status update")),
            ]
        )

        let entries = ClipboardPickerSearch.folderEntries(in: folder, query: "incident")

        XCTAssertEqual(entries, [
            .snippet(groupTitle: "Work", snippet: Snippet(title: "Incident", content: "Status update")),
        ])
    }

    func testSnippetsOnlyRootEntriesExcludeHistory() {
        let history = [ClipboardItem(plainText: "History")]
        let groups = [
            SnippetGroup(title: "Work", snippets: [Snippet(title: "Greeting", content: "Hello")]),
        ]

        let entries = ClipboardPickerSearch.rootEntries(
            history: history,
            snippetGroups: groups,
            query: "",
            mode: .snippetsOnly
        )

        XCTAssertEqual(entries.map(\.title), ["Snippets", "Work"])
    }

    func testEmptyQueryShowsHistoryThenSnippetsInSourceOrder() {
        let firstHistory = ClipboardItem(plainText: "Recent clipboard")
        let secondHistory = ClipboardItem(plainText: "Older clipboard")
        let groups = [
            SnippetGroup(
                title: "Work",
                snippets: [
                    Snippet(title: "Greeting", content: "Hello"),
                    Snippet(title: "Signoff", content: "Thanks"),
                ]
            ),
            SnippetGroup(
                title: "Personal",
                snippets: [
                    Snippet(title: "Address", content: "123 Main"),
                ]
            ),
        ]

        let results = ClipboardPickerSearch.results(
            history: [firstHistory, secondHistory],
            snippetGroups: groups,
            query: "",
            mode: .all
        )

        XCTAssertEqual(results, [
            .history(firstHistory),
            .history(secondHistory),
            .snippet(groupTitle: "Work", snippet: groups[0].snippets[0]),
            .snippet(groupTitle: "Work", snippet: groups[0].snippets[1]),
            .snippet(groupTitle: "Personal", snippet: groups[1].snippets[0]),
        ])
    }

    func testSearchMatchesHistoryFullTextCaseInsensitively() {
        let matching = ClipboardItem(plainText: "First line\nNeedle is on another line")
        let nonmatching = ClipboardItem(plainText: "Other value")

        let results = ClipboardPickerSearch.results(
            history: [matching, nonmatching],
            snippetGroups: [],
            query: "needle",
            mode: .all
        )

        XCTAssertEqual(results, [.history(matching)])
    }

    func testSearchMatchesSnippetGroupTitleSnippetTitleAndContent() {
        let groupMatched = SnippetGroup(
            title: "Infrastructure",
            snippets: [Snippet(title: "Deploy", content: "ship it")]
        )
        let titleMatched = SnippetGroup(
            title: "Work",
            snippets: [Snippet(title: "Incident reply", content: "looking")]
        )
        let contentMatched = SnippetGroup(
            title: "Personal",
            snippets: [Snippet(title: "Note", content: "incident followup")]
        )
        let nonmatching = SnippetGroup(
            title: "Other",
            snippets: [Snippet(title: "Todo", content: "later")]
        )

        let results = ClipboardPickerSearch.results(
            history: [],
            snippetGroups: [groupMatched, titleMatched, contentMatched, nonmatching],
            query: "incident",
            mode: .all
        )

        XCTAssertEqual(results, [
            .snippet(groupTitle: "Work", snippet: titleMatched.snippets[0]),
            .snippet(groupTitle: "Personal", snippet: contentMatched.snippets[0]),
        ])

        let groupResults = ClipboardPickerSearch.results(
            history: [],
            snippetGroups: [groupMatched, titleMatched, contentMatched, nonmatching],
            query: "infra",
            mode: .all
        )

        XCTAssertEqual(groupResults, [
            .snippet(groupTitle: "Infrastructure", snippet: groupMatched.snippets[0]),
        ])
    }

    func testSnippetsOnlyModeExcludesHistory() {
        let item = ClipboardItem(plainText: "Needle")
        let group = SnippetGroup(
            title: "Work",
            snippets: [Snippet(title: "Needle", content: "snippet")]
        )

        let results = ClipboardPickerSearch.results(
            history: [item],
            snippetGroups: [group],
            query: "needle",
            mode: .snippetsOnly
        )

        XCTAssertEqual(results, [
            .snippet(groupTitle: "Work", snippet: group.snippets[0]),
        ])
    }
}
