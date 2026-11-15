import XCTest
@testable import ShortyCore

final class LaunchOptionsTests: XCTestCase {
    func testParsesListWindowsMode() throws {
        let options = try LaunchOptions(arguments: ["Shorty", "--list-windows"])
        XCTAssertEqual(options.mode, .listWindows)
    }

    func testParsesValidateMode() throws {
        let options = try LaunchOptions(arguments: ["Shorty", "--validate-config"])
        XCTAssertEqual(options.mode, .validateConfig)
    }

    func testParsesVerboseListMode() throws {
        let options = try LaunchOptions(arguments: ["Shorty", "--list-windows", "--verbose"])
        XCTAssertEqual(options.mode, .listWindows)
        XCTAssertEqual(options.windowListFormat, .verbose)
    }

    func testDefaultConfigPath() throws {
        let options = try LaunchOptions(arguments: ["Shorty"], fileExists: { _ in false })
        XCTAssertEqual(options.configURL.path, NSHomeDirectory() + "/.shorty/config.yaml")
    }

    func testPrefersCurrentDefaultConfigPathWhenBothExist() throws {
        let options = try LaunchOptions(arguments: ["Shorty"], fileExists: { _ in true })
        XCTAssertEqual(options.configURL.path, NSHomeDirectory() + "/.shorty/config.yaml")
    }

    func testFallsBackToLegacyConfigPath() throws {
        let legacyPath = LaunchOptions.legacyDefaultConfigURL.path
        let options = try LaunchOptions(arguments: ["Shorty"], fileExists: { $0.path == legacyPath })
        XCTAssertEqual(options.configURL.path, NSHomeDirectory() + "/config/shorty.yaml")
    }

    func testExplicitConfigPathIgnoresDefaults() throws {
        let options = try LaunchOptions(
            arguments: ["Shorty", "--config", "/tmp/custom.yaml"],
            fileExists: { _ in true }
        )
        XCTAssertEqual(options.configURL.path, "/tmp/custom.yaml")
    }
}
