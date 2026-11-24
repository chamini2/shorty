import XCTest
@testable import ShortyCore

final class FileSearchTests: XCTestCase {
    private func hit(_ path: String) -> FileHit {
        let url = URL(fileURLWithPath: path)

        return FileHit(
            name: url.lastPathComponent,
            path: path,
            folder: url.deletingLastPathComponent().lastPathComponent
        )
    }

    func testThePathIsWrittenTheWayAPersonWritesIt() {
        let home = NSHomeDirectory()

        XCTAssertEqual(hit("\(home)/Projects/shorty/README.md").displayPath, "~/Projects/shorty")
        // Outside home there is no tilde to use.
        XCTAssertEqual(hit("/etc/hosts").displayPath, "/etc")
    }

    func testTheRowShowsTheNameAboveThePath() throws {
        let home = NSHomeDirectory()
        let entry = try XCTUnwrap(CommandCatalog.fileEntries([hit("\(home)/Desktop/notes.txt")]).first)

        XCTAssertEqual(entry.title, "notes.txt")
        XCTAssertEqual(entry.detail, "~/Desktop")
        XCTAssertEqual(entry.action, .openFile(path: "\(home)/Desktop/notes.txt"))
        // Two lines and the file's own icon: half a search comes back with
        // the same name and only the path tells them apart.
        XCTAssertEqual(entry.layout, .detailed)
        XCTAssertEqual(entry.iconPath, "\(home)/Desktop/notes.txt")
    }

    func testFilesAreReachableFromTheCommandBox() throws {
        let entry = try XCTUnwrap(CommandCatalog.rootEntries(query: "").first { $0.title == "Files" })

        XCTAssertEqual(entry.destination, .search(.files))
        XCTAssertTrue(CommandCatalog.rootEntries(query: "file").contains { $0.title == "Files" })
    }

    func testTheComputersOwnFilesAreLeftOut() {
        // A content search answers almost any word with browser cache
        // otherwise, and none of it is anything to open.
        XCTAssertFalse(FileSearcher.isWorthShowing("\(NSHomeDirectory())/Library/Caches/thing.db"))
        XCTAssertFalse(FileSearcher.isWorthShowing("\(NSHomeDirectory())/.config/fish/config.fish"))
        XCTAssertFalse(FileSearcher.isWorthShowing("\(NSHomeDirectory())/code/node_modules/react/README.md"))
        XCTAssertTrue(FileSearcher.isWorthShowing("\(NSHomeDirectory())/Projects/shorty/README.md"))
    }
}
