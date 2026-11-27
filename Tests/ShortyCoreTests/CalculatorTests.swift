import XCTest
@testable import ShortyCore

final class CalculatorTests: XCTestCase {
    private func value(_ text: String) -> Double? {
        guard Calculator.isWorthEvaluating(text) else {
            return nil
        }

        return Calculator.evaluate(text)
    }

    private func assertValue(_ text: String, _ expected: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let result = value(text) else {
            return XCTFail("`\(text)` had no answer", file: file, line: line)
        }

        XCTAssertEqual(result, expected, accuracy: 1e-9, text, file: file, line: line)
    }

    func testTheUsualArithmetic() {
        assertValue("12 * 34", 408)
        assertValue("2 + 3 * 4", 14)
        assertValue("(2 + 3) * 4", 20)
        assertValue("10 / 4", 2.5)
        assertValue("-5 + 2", -3)
    }

    func testPowersGroupToTheRightAndBindTighterThanAMinus() {
        assertValue("2^10", 1024)
        assertValue("2**10", 1024)
        // 2^(3^2), as on paper, not (2^3)^2.
        assertValue("2^3^2", 512)
        // -(2^2), not (-2)^2.
        assertValue("-2^2", -4)
        assertValue("-2 * 3", -6)
    }

    func testFunctionsTakeTheirArgumentWithOrWithoutParentheses() {
        assertValue("sqrt(100)", 10)
        assertValue("sqrt 100", 10)
        // A function binds tighter than any operator.
        assertValue("sqrt 16 + 9", 13)
        assertValue("max(3, 9, 2)", 9)
        assertValue("log(100)", 2)
        assertValue("log(2, 8)", 3)
        assertValue("ln(e)", 1)
        assertValue("pi", .pi)
    }

    func testPercentSignMeansRemainderOrPercentageDependingOnWhatFollows() {
        // A value after it makes it a remainder.
        assertValue("10 % 3", 1)
        assertValue("100 % 7", 2)
        // Nothing after it makes it a percentage.
        assertValue("20%", 0.2)
        // Added or subtracted, it is a share of the other side.
        assertValue("45 + 20%", 54)
        assertValue("45 - 10%", 40.5)
        assertValue("20% of 45", 9)
        // Part of a larger term, it is just a fifth again.
        assertValue("45 + 20% * 2", 45.4)
    }

    func testACommaGroupsDigitsOnlyInThrees() {
        // `log(2,8)` read as `log(28)` answered 1.447 with no sign of being
        // wrong, which is worse than answering nothing.
        assertValue("log(2,8)", 3)
        assertValue("max(3,9,2)", 9)
        assertValue("1,234 + 1", 1235)
        assertValue("1,234,567 + 1", 1234568)
        assertValue("1_000_000 / 4", 250_000)
        XCTAssertNil(value("12,34"))
    }

    func testNothingIsAnsweredWhenThereIsNoSum() {
        // A bare number answers itself, and a ten digit one is a timestamp
        // the epoch conversion already explains.
        XCTAssertNil(value("42"))
        XCTAssertNil(value("1763481600"))
        // Commands must never be mistaken for arithmetic.
        XCTAssertNil(value("clipboard"))
        XCTAssertNil(value("maximize"))
        // Half typed, which is the normal state of a box being typed into.
        XCTAssertNil(value("2 +"))
        XCTAssertNil(value("(2 + 3"))
        // An infinity tells the reader nothing they did not know.
        XCTAssertNil(value("10 / 0"))
    }

    func testTheAnswerIsGroupedToReadAndPlainToPaste() {
        XCTAssertEqual(Calculator.display(1234567.89), "1,234,567.89")
        XCTAssertEqual(Calculator.plain(1234567.89), "1234567.89")
        XCTAssertEqual(Calculator.display(408), "408")
        // Floating point dust is swept up: 0.1 + 0.2 is 0.3 here.
        XCTAssertEqual(Calculator.plain(0.1 + 0.2), "0.3")
    }

    func testTheRowLeadsWithTheAnswer() throws {
        let entry = try XCTUnwrap(
            CommandCatalog.rootEntries(query: "1_000_000 / 4").first { $0.id == "result:calculator" }
        )

        // What was typed stays on the left and the answer sits where every
        // other result row puts it, grouped for reading.
        XCTAssertEqual(entry.title, "1_000_000 / 4")
        XCTAssertEqual(entry.trailing, "250,000")
        XCTAssertEqual(entry.layout, .result)
        // Without the commas, since a comma pasted into a spreadsheet is
        // not a number.
        XCTAssertEqual(entry.action, .copyText("250000"))
    }
}
