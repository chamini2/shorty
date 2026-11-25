import XCTest
@testable import ShortyCore

final class RecentAppStoreTests: XCTestCase {
    private var directory: URL!
    private var database: ShortyDatabase!

    private let apps = ["Airmail", "Safari", "Slack", "Zed"].map {
        InstalledApplication(name: $0, path: "/Applications/\($0).app", directoryName: "Applications")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RecentApps-\(UUID().uuidString)")
        database = try ShortyDatabase(url: directory.appendingPathComponent("Shorty.sqlite"))
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func listedApps(opens: [String: Int]) throws -> [String] {
        let root = CommandCatalog.rootEntries(query: "", applications: apps, applicationOpens: opens)
        let group = try XCTUnwrap(root.first { $0.title == "Applications" })

        guard case let .list(rows) = group.destination else {
            XCTFail("Expected Applications to lead to a list")
            return []
        }

        return rows.map(\.title)
    }

    func testTheListIsAlphabeticalUntilSomethingHasBeenOpened() throws {
        XCTAssertEqual(try listedApps(opens: [:]), ["Airmail", "Safari", "Slack", "Zed"])
    }

    func testOpeningIsCountedRatherThanDated() {
        let store = RecentAppStore(database: database)
        store.record("/Applications/Slack.app")
        store.record("/Applications/Slack.app")
        store.record("/Applications/Zed.app")

        // Counted, so an app opened often stays high on a day it has not
        // been opened at all.
        XCTAssertEqual(store.opens()["/Applications/Slack.app"], 2)
        XCTAssertEqual(store.opens()["/Applications/Zed.app"], 1)
        XCTAssertNil(store.opens()["/Applications/Safari.app"])
    }

    func testOpenedAppsLeadAndTheRestStayAlphabetical() throws {
        let store = RecentAppStore(database: database)
        store.record("/Applications/Slack.app")
        store.record("/Applications/Slack.app")
        store.record("/Applications/Zed.app")

        XCTAssertEqual(
            try listedApps(opens: store.opens()),
            ["Slack", "Zed", "Airmail", "Safari"]
        )
    }

    func testCountsSurviveReopening() throws {
        RecentAppStore(database: database).record("/Applications/Slack.app")

        let reopened = RecentAppStore(
            database: try ShortyDatabase(url: directory.appendingPathComponent("Shorty.sqlite"))
        )

        XCTAssertEqual(reopened.opens()["/Applications/Slack.app"], 1)
    }

    func testAnAppRowCarriesWhatIsNeededToOpenAndRevealIt() throws {
        let rows = try listedApps(opens: [:])
        XCTAssertEqual(rows.count, 4)

        let root = CommandCatalog.rootEntries(query: "", applications: apps)
        let group = try XCTUnwrap(root.first { $0.title == "Applications" })

        guard case let .list(entries) = group.destination else {
            return XCTFail("Expected Applications to lead to a list")
        }

        let safari = try XCTUnwrap(entries.first { $0.title == "Safari" })
        XCTAssertEqual(safari.action, .openApplication(path: "/Applications/Safari.app"))
        // The row draws the app's own icon, which the catalog only points at.
        XCTAssertEqual(safari.iconPath, "/Applications/Safari.app")
    }
}
