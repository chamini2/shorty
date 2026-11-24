import XCTest
@testable import ShortyCore

final class WindowCascadeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 25, width: 1512, height: 920)

    private func frames(_ count: Int, size: CGSize = CGSize(width: 1000, height: 650), anchor: CGPoint? = nil) -> [CGRect] {
        WindowGeometryPlanner.cascadeFrames(
            sizes: Array(repeating: size, count: count),
            on: screen,
            from: anchor
        )
    }

    func testEachWindowStepsDownAndRightOfTheLast() {
        let laid = frames(3)

        XCTAssertEqual(laid.count, 3)
        XCTAssertEqual(laid[1].minX - laid[0].minX, WindowGeometryPlanner.cascadeStep)
        XCTAssertEqual(laid[1].minY - laid[0].minY, WindowGeometryPlanner.cascadeStep)
        // Room to spare, so the windows keep the size they came with.
        XCTAssertEqual(laid[0].size, CGSize(width: 1000, height: 650))
    }

    func testTheStepTightensRatherThanRunningOffTheScreen() {
        let many = frames(20)
        let step = many[1].minX - many[0].minX

        XCTAssertLessThan(step, WindowGeometryPlanner.cascadeStep)
        XCTAssertGreaterThan(step, 0)
        XCTAssertTrue(many.allSatisfy { screen.contains($0) })
    }

    func testFullHeightWindowsAreTrimmedSoTheStackHasRoomToStep() {
        // The case that put every window along the top: a window as tall as
        // the display leaves nothing to step down into.
        let laid = frames(4, size: CGSize(width: screen.width, height: screen.height))

        XCTAssertGreaterThan(laid[1].minY - laid[0].minY, 0)
        XCTAssertLessThan(laid[0].height, screen.height)
        XCTAssertTrue(laid.allSatisfy { screen.contains($0) })
    }

    func testOneWindowIsLeftWhereTheStackStarts() {
        XCTAssertEqual(frames(1).first?.origin, screen.origin)
    }

    func testAPinnedWindowIsTheCornerTheRestFlowFrom() {
        let anchor = CGPoint(x: 300, y: 200)
        let laid = frames(4, anchor: anchor)

        XCTAssertEqual(laid[0].origin, anchor)
        XCTAssertEqual(laid[1].minX - laid[0].minX, WindowGeometryPlanner.cascadeStep)
        XCTAssertTrue(laid.allSatisfy { screen.contains($0) })
    }

    func testAPinnedWindowNearTheEdgeStillLeavesRoomToStack() {
        // Anchored in the bottom right there would be nowhere to stack, so
        // the corner is pulled back into the display.
        let laid = frames(4, anchor: CGPoint(x: 1300, y: 800))

        XCTAssertLessThan(laid[0].minX, 1300)
        XCTAssertLessThan(laid[0].minY, 800)
        XCTAssertGreaterThan(laid[1].minX - laid[0].minX, 0)
        XCTAssertTrue(laid.allSatisfy { screen.contains($0) })
    }

    func testBothCascadesAreOfferedInTheWindowGroup() throws {
        let window = try XCTUnwrap(CommandCatalog.rootEntries(query: "").first { $0.title == "Window" })

        guard case let .list(moves) = window.destination else {
            return XCTFail("Expected Window to lead to a list")
        }

        XCTAssertEqual(
            moves.first { $0.title == "Cascade Windows" }?.action,
            .moveWindow(.cascade(WindowCascadeOptions(scope: .space)))
        )
        XCTAssertEqual(
            moves.first { $0.title == "Cascade App Windows" }?.action,
            .moveWindow(.cascade(WindowCascadeOptions(scope: .application)))
        )
    }
}
