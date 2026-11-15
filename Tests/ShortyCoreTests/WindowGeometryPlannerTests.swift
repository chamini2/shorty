import CoreGraphics
import XCTest
@testable import ShortyCore

final class WindowGeometryPlannerTests: XCTestCase {
    private let oneScreen = CGRect(x: 0, y: 39, width: 2056, height: 1290)

    func testResizeStepsByAShareOfTheDisplayAroundTheCentre() throws {
        let window = CGRect(x: 600, y: 400, width: 900, height: 600)

        let larger = try XCTUnwrap(
            WindowGeometryPlanner.resizedFrame(for: window, screens: [oneScreen], by: 0.05)
        )
        XCTAssertEqual(larger.width, 900 + oneScreen.width * 0.05, accuracy: 1)
        XCTAssertEqual(larger.midX, window.midX, accuracy: 1)
        XCTAssertEqual(larger.midY, window.midY, accuracy: 1)

        let smaller = try XCTUnwrap(
            WindowGeometryPlanner.resizedFrame(for: window, screens: [oneScreen], by: -0.05)
        )
        XCTAssertEqual(smaller.width, 900 - oneScreen.width * 0.05, accuracy: 1)
    }

    func testResizeStopsAtTheDisplayAndAtAUsableMinimum() {
        var grown = CGRect(x: 600, y: 400, width: 900, height: 600)
        while let next = WindowGeometryPlanner.resizedFrame(for: grown, screens: [oneScreen], by: 0.05) {
            grown = next
        }

        XCTAssertEqual(grown, oneScreen, "fills the display and goes no further")
        XCTAssertNil(WindowGeometryPlanner.resizedFrame(for: grown, screens: [oneScreen], by: 0.05))

        var shrunk = CGRect(x: 600, y: 400, width: 900, height: 600)
        while let next = WindowGeometryPlanner.resizedFrame(for: shrunk, screens: [oneScreen], by: -0.05) {
            shrunk = next
        }

        XCTAssertGreaterThanOrEqual(shrunk.width, oneScreen.width * 0.2 - 1)
        XCTAssertNil(WindowGeometryPlanner.resizedFrame(for: shrunk, screens: [oneScreen], by: -0.05))
    }

    func testGrowingNearAnEdgePullsTheWindowBackOnScreen() throws {
        let edge = CGRect(x: oneScreen.maxX - 500, y: oneScreen.minY + 10, width: 480, height: 300)

        let grown = try XCTUnwrap(
            WindowGeometryPlanner.resizedFrame(for: edge, screens: [oneScreen], by: 0.05)
        )
        XCTAssertTrue(oneScreen.contains(grown))
    }

    func testMonitorMoveNeedsASecondDisplay() {
        let screen = CGRect(x: 0, y: 39, width: 2056, height: 1290)
        let window = CGRect(x: 172, y: 132, width: 1728, height: 1071)

        XCTAssertNil(WindowGeometryPlanner.monitorMoveFrame(for: window, screens: [screen], direction: .left))
        XCTAssertNil(WindowGeometryPlanner.monitorMoveFrame(for: window, screens: [screen], direction: .right))
    }

    func testMonitorMoveScalesIntoTheOtherDisplayAndBack() throws {
        let screens = [
            CGRect(x: 0, y: 39, width: 2056, height: 1290),
            CGRect(x: 2056, y: 0, width: 1920, height: 1080),
        ]
        let window = CGRect(x: 400, y: 300, width: 900, height: 700)

        let moved = try XCTUnwrap(
            WindowGeometryPlanner.monitorMoveFrame(for: window, screens: screens, direction: .right)
        )
        XCTAssertTrue(screens[1].contains(moved), "lands inside the other display")
        XCTAssertLessThan(moved.width, window.width, "scaled to the smaller display")

        let returned = try XCTUnwrap(
            WindowGeometryPlanner.monitorMoveFrame(for: moved, screens: screens, direction: .left)
        )
        XCTAssertTrue(WindowGeometryPlanner.isApproximately(returned, window), "comes back where it was")
    }

    func testHalfCycleWrapsWithinOneDisplay() throws {
        let screen = CGRect(x: 0, y: 39, width: 2056, height: 1290)
        let window = CGRect(x: 172, y: 132, width: 1728, height: 1071)

        let left = try XCTUnwrap(
            WindowGeometryPlanner.halfCycleFrame(for: window, screens: [screen], direction: .left)
        )
        XCTAssertEqual(left, CGRect(x: 0, y: 39, width: 1028, height: 1290))

        // With nowhere else to go, pressing left again swaps to the other half.
        let again = try XCTUnwrap(
            WindowGeometryPlanner.halfCycleFrame(for: left, screens: [screen], direction: .left)
        )
        XCTAssertEqual(again, CGRect(x: 1028, y: 39, width: 1028, height: 1290))
    }

    func testSizeComparisonToleratesSmallDifferences() {
        let target = CGSize(width: 2056, height: 1290)

        XCTAssertTrue(WindowGeometryPlanner.isApproximately(CGSize(width: 2056, height: 1290), target))
        XCTAssertTrue(WindowGeometryPlanner.isApproximately(CGSize(width: 2055, height: 1291), target))

        // A window that kept its own size is not approximately the target.
        XCTAssertFalse(WindowGeometryPlanner.isApproximately(CGSize(width: 1728, height: 1071), target))
    }

    func testHalfFramesUseVisibleScreenHalves() {
        let screen = CGRect(x: 100, y: 50, width: 1000, height: 800)

        XCTAssertEqual(
            WindowGeometryPlanner.halfFrame(on: screen, half: .left),
            CGRect(x: 100, y: 50, width: 500, height: 800)
        )
        XCTAssertEqual(
            WindowGeometryPlanner.halfFrame(on: screen, half: .right),
            CGRect(x: 600, y: 50, width: 500, height: 800)
        )
    }

    func testHalfCycleMovesToCurrentHalfWhenWindowIsNotAlreadyThere() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 1200, height: 900),
        ]
        let window = CGRect(x: 1200, y: 100, width: 600, height: 500)

        XCTAssertEqual(
            WindowGeometryPlanner.halfCycleFrame(for: window, screens: screens, direction: .left),
            CGRect(x: 1000, y: 0, width: 600, height: 900)
        )
    }

    func testHalfCycleMovesLeftToPreviousMonitorRightHalf() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 1200, height: 900),
        ]
        let window = CGRect(x: 1000, y: 0, width: 600, height: 900)

        XCTAssertEqual(
            WindowGeometryPlanner.halfCycleFrame(for: window, screens: screens, direction: .left),
            CGRect(x: 500, y: 0, width: 500, height: 800)
        )
    }

    func testHalfCycleWrapsLeftmostLeftHalfToRightmostRightHalf() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 1200, height: 900),
        ]
        let window = CGRect(x: 0, y: 0, width: 500, height: 800)

        XCTAssertEqual(
            WindowGeometryPlanner.halfCycleFrame(for: window, screens: screens, direction: .left),
            CGRect(x: 1600, y: 0, width: 600, height: 900)
        )
    }

    func testHalfCycleWrapsRightmostRightHalfToLeftmostLeftHalf() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 1200, height: 900),
        ]
        let window = CGRect(x: 1600, y: 0, width: 600, height: 900)

        XCTAssertEqual(
            WindowGeometryPlanner.halfCycleFrame(for: window, screens: screens, direction: .right),
            CGRect(x: 0, y: 0, width: 500, height: 800)
        )
    }

    func testHalfCycleTreatsOversizedLeftAnchoredWindowAsLeftHalf() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 1200, height: 900),
        ]
        let window = CGRect(x: 0, y: 0, width: 700, height: 800)

        XCTAssertEqual(
            WindowGeometryPlanner.halfCycleFrame(for: window, screens: screens, direction: .left),
            CGRect(x: 1600, y: 0, width: 600, height: 900)
        )
    }

    func testHalfCycleTreatsOversizedRightAnchoredWindowAsRightHalf() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 1200, height: 900),
        ]
        let window = CGRect(x: 300, y: 0, width: 700, height: 800)

        XCTAssertEqual(
            WindowGeometryPlanner.halfCycleFrame(for: window, screens: screens, direction: .right),
            CGRect(x: 1000, y: 0, width: 600, height: 900)
        )
    }

    func testHalfCycleDoesNotTreatMaximizedWindowAsAnchoredHalf() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertEqual(
            WindowGeometryPlanner.halfCycleFrame(for: window, screens: screens, direction: .right),
            CGRect(x: 500, y: 0, width: 500, height: 800)
        )
    }

    func testApproximatelyUsesToleranceForHalfDetection() {
        let target = CGRect(x: 0, y: 0, width: 500, height: 800)

        XCTAssertTrue(
            WindowGeometryPlanner.isApproximately(
                CGRect(x: 8, y: -4, width: 492, height: 808),
                target,
                tolerance: 12
            )
        )
        XCTAssertFalse(
            WindowGeometryPlanner.isApproximately(
                CGRect(x: 20, y: 0, width: 500, height: 800),
                target,
                tolerance: 12
            )
        )
    }

    func testApproximatelyUsesToleranceForPoints() {
        XCTAssertTrue(
            WindowGeometryPlanner.isApproximately(
                CGPoint(x: 108, y: 46),
                CGPoint(x: 100, y: 50),
                tolerance: 12
            )
        )
        XCTAssertFalse(
            WindowGeometryPlanner.isApproximately(
                CGPoint(x: 120, y: 50),
                CGPoint(x: 100, y: 50),
                tolerance: 12
            )
        )
    }

    func testMaximizeFrameUsesCurrentScreen() {
        let screen = CGRect(x: 100, y: 50, width: 1000, height: 800)

        XCTAssertEqual(WindowGeometryPlanner.maximizeFrame(on: screen), screen)
    }

    func testAccessibilityFrameConvertsAppKitVisibleFrameToTopLeftCoordinates() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let visibleFrame = CGRect(x: 0, y: 60, width: 1000, height: 710)
        let displayBounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertEqual(
            WindowGeometryPlanner.accessibilityFrame(
                screenFrame: screenFrame,
                visibleFrame: visibleFrame,
                displayBounds: displayBounds
            ),
            CGRect(x: 0, y: 30, width: 1000, height: 710)
        )
    }

    func testAccessibilityFrameConvertsOffsetDisplay() {
        let screenFrame = CGRect(x: 1000, y: -100, width: 1200, height: 900)
        let visibleFrame = CGRect(x: 1000, y: -50, width: 1200, height: 830)
        let displayBounds = CGRect(x: 1000, y: 0, width: 1200, height: 900)

        XCTAssertEqual(
            WindowGeometryPlanner.accessibilityFrame(
                screenFrame: screenFrame,
                visibleFrame: visibleFrame,
                displayBounds: displayBounds
            ),
            CGRect(x: 1000, y: 20, width: 1200, height: 830)
        )
    }

    func testFittingOriginKeepsTargetOriginWhenActualSizeFitsScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]

        XCTAssertEqual(
            WindowGeometryPlanner.fittingOrigin(
                for: CGRect(x: 500, y: 0, width: 500, height: 800),
                actualSize: CGSize(width: 480, height: 700),
                screens: screens
            ),
            CGPoint(x: 500, y: 0)
        )
    }

    func testFittingOriginClampsOversizedRightHalfWindowToScreenEdge() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]

        XCTAssertEqual(
            WindowGeometryPlanner.fittingOrigin(
                for: CGRect(x: 500, y: 0, width: 500, height: 800),
                actualSize: CGSize(width: 700, height: 760),
                screens: screens
            ),
            CGPoint(x: 300, y: 0)
        )
    }

    func testFittingOriginUsesScreenMinimumWhenWindowIsLargerThanScreen() {
        let screens = [CGRect(x: 100, y: 50, width: 1000, height: 800)]

        XCTAssertEqual(
            WindowGeometryPlanner.fittingOrigin(
                for: CGRect(x: 600, y: 50, width: 500, height: 800),
                actualSize: CGSize(width: 1200, height: 900),
                screens: screens
            ),
            CGPoint(x: 100, y: 50)
        )
    }

    func testMonitorMovePreservesProportionalGeometry() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1000, height: 800),
            CGRect(x: 1000, y: 0, width: 2000, height: 1000),
        ]
        let window = CGRect(x: 250, y: 200, width: 500, height: 400)

        XCTAssertEqual(
            WindowGeometryPlanner.monitorMoveFrame(for: window, screens: screens, direction: .right),
            CGRect(x: 1500, y: 250, width: 1000, height: 500)
        )
    }

    func testScreenSelectionUsesCenterBeforeIntersectionFallback() {
        let screens = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
        ]

        XCTAssertEqual(
            WindowGeometryPlanner.screenIndex(
                containing: CGRect(x: 120, y: 20, width: 40, height: 40),
                screens: screens
            ),
            1
        )
    }

    func testScreenSelectionFallsBackToLargestIntersection() {
        let screens = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 200, y: 0, width: 100, height: 100),
        ]

        XCTAssertEqual(
            WindowGeometryPlanner.screenIndex(
                containing: CGRect(x: 50, y: 90, width: 40, height: 30),
                screens: screens
            ),
            0
        )
    }
}
