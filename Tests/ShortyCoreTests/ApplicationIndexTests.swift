import XCTest
@testable import ShortyCore

final class ApplicationIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ApplicationIndexTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    private func makeBundle(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
    }

    func testFindsAppsAndTheOnesOneFolderDown() throws {
        try makeBundle("Apps/Safari.app")
        try makeBundle("Apps/Utilities/Terminal.app")
        try makeBundle("Apps/NotAnApp.txt")

        let found = ApplicationScanner.scan(directories: [root.appendingPathComponent("Apps")])

        XCTAssertEqual(found.map(\.name), ["Safari", "Terminal"])
        XCTAssertEqual(found.first { $0.name == "Terminal" }?.directoryName, "Utilities")
    }

    func testDoesNotWalkIntoABundle() throws {
        // An app bundle is a directory; the scan must not go hunting inside it.
        try makeBundle("Apps/Xcode.app")
        try makeBundle("Apps/Xcode.app/Contents/Applications/Instruments.app")

        let found = ApplicationScanner.scan(directories: [root.appendingPathComponent("Apps")])

        XCTAssertEqual(found.map(\.name), ["Xcode"])
    }

    func testTheFirstOfARepeatedNameWins() throws {
        try makeBundle("First/Mail.app")
        try makeBundle("Second/Mail.app")

        let found = ApplicationScanner.scan(directories: [
            root.appendingPathComponent("First"),
            root.appendingPathComponent("Second"),
        ])

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.directoryName, "First")
    }

    func testTheIndexScansOnceUntilItIsStale() {
        var scans = 0
        let index = ApplicationIndex {
            scans += 1
            return [InstalledApplication(name: "Mail", path: "/Applications/Mail.app", directoryName: "Applications")]
        }
        let start = Date()

        XCTAssertEqual(index.current(now: start).map(\.name), ["Mail"])
        _ = index.current(now: start.addingTimeInterval(1))
        XCTAssertEqual(scans, 1, "a second opening of the box should not rescan the disk")

        _ = index.current(now: start.addingTimeInterval(ApplicationIndex.refreshInterval + 1))
        XCTAssertEqual(scans, 2, "an installed app should be found eventually")
    }

    func testApplicationsReachTheCommandBoxAsAGroup() throws {
        let apps = [
            InstalledApplication(name: "Safari", path: "/Applications/Safari.app", directoryName: "Applications"),
            InstalledApplication(name: "Terminal", path: "/System/Applications/Utilities/Terminal.app", directoryName: "Utilities"),
        ]
        let entries = CommandCatalog.rootEntries(query: "", applications: apps)
        let group = try XCTUnwrap(entries.first { $0.title == "Applications" })

        XCTAssertEqual(group.detail, "2 installed")

        guard case let .list(rows) = group.destination else {
            return XCTFail("Expected Applications to lead to a list")
        }

        XCTAssertEqual(rows.map(\.title), ["Safari", "Terminal"])
        XCTAssertEqual(rows.first?.action, .openApplication(path: "/Applications/Safari.app"))
        // The row draws the app's own icon, which the catalog only points at.
        XCTAssertEqual(rows.first?.iconPath, "/Applications/Safari.app")
    }

    func testSearchFindsAnAppAndSaysWhereItCameFrom() {
        let apps = [InstalledApplication(name: "Safari", path: "/Applications/Safari.app", directoryName: "Applications")]
        let entries = CommandCatalog.rootEntries(query: "saf", applications: apps)

        XCTAssertEqual(entries.map(\.title), ["Applications › Safari"])
    }

    func testOnlyTenAppsAreSurfacedAtOnce() {
        let apps = (0..<40).map {
            InstalledApplication(name: "Note\($0)", path: "/Applications/Note\($0).app", directoryName: "Applications")
        }
        let entries = CommandCatalog.rootEntries(query: "note", applications: apps)

        XCTAssertEqual(entries.count, 10)
    }
}
