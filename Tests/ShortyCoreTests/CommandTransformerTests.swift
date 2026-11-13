import XCTest
@testable import ShortyCore

final class CommandTransformerTests: XCTestCase {
    func testStructuredPrefixRendersRemainingStringAndRegexPlaceholders() {
        let transformer = CommandTransformer(
            name: "Bytes",
            parts: [
                .regex(name: "bytes", pattern: #"\d+"#),
                .string("to"),
                .regex(name: "kb/mb/gb/tb", pattern: #"kb|mb|gb|tb"#),
            ]
        ) { _, _ in
            "converted"
        }

        let results = CommandTransformerEngine.evaluate("1223 t", transformers: [transformer])

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].displayText, "1223 to kb/mb/gb/tb")
        XCTAssertEqual(results[0].segments, [
            CommandDisplaySegment(text: "1223 t", kind: .matched),
            CommandDisplaySegment(text: "o kb/mb/gb/tb", kind: .placeholder),
        ])
        XCTAssertNil(results[0].resultText)
    }

    func testStructuredFullMatchRunsTransformerWithCaptures() {
        let transformer = CommandTransformer(
            name: "Bytes",
            parts: [
                .regex(name: "bytes", pattern: #"\d+"#),
                .string("to"),
                .regex(name: "unit", pattern: #"kb|mb|gb|tb"#),
            ]
        ) { captures, _ in
            "\(captures["bytes"] ?? "") \(captures["unit"] ?? "")"
        }

        let results = CommandTransformerEngine.evaluate("1223 to mb", transformers: [transformer])

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].displayText, "1223 to mb")
        XCTAssertEqual(results[0].resultText, "1223 mb")
    }

    func testStringPartsAdvanceOnlyAfterFullMatch() {
        let transformer = CommandTransformer(
            name: "Bytes",
            parts: [
                .regex(name: "bytes", pattern: #"\d+"#),
                .string("to"),
                .regex(name: "unit", pattern: #"kb|mb"#),
            ]
        ) { _, _ in
            "converted"
        }

        XCTAssertTrue(CommandTransformerEngine.evaluate("1223 t mb", transformers: [transformer]).isEmpty)
    }

    func testRegexPartsRequireFullTokenMatch() {
        let transformer = CommandTransformer(
            name: "Epoch Seconds",
            parts: [.regex(name: "seconds", pattern: #"\d{10}"#)]
        ) { _, _ in
            "date"
        }

        XCTAssertTrue(CommandTransformerEngine.evaluate("178", transformers: [transformer]).isEmpty)
    }

    func testInvalidExtraInputProducesNoMatch() {
        let transformer = CommandTransformer(
            name: "Epoch Seconds",
            parts: [.regex(name: "seconds", pattern: #"\d{10}"#)]
        ) { _, _ in
            "date"
        }

        XCTAssertTrue(CommandTransformerEngine.evaluate("1782275959 extra", transformers: [transformer]).isEmpty)
    }

    func testRunsTransformerWhenAllRegexPartsMatchBeforeAllStringsAreEntered() {
        let transformer = CommandTransformer(
            name: "Bytes",
            parts: [
                .regex(name: "bytes", pattern: #"\d+"#),
                .string("bytes"),
            ]
        ) { captures, _ in
            captures["bytes"] ?? ""
        }

        let results = CommandTransformerEngine.evaluate("1223 b", transformers: [transformer])

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].displayText, "1223 bytes")
        XCTAssertEqual(results[0].resultText, "1223")
    }

    func testEpochFormatsUTCAndTheLocalZoneWithRelativeAge() {
        let now = Date(timeIntervalSince1970: 90_061)
        let result = CommandTransformerEngine.formatUTCAndLocal(
            Date(timeIntervalSince1970: 0),
            now: now,
            localTimeZone: TimeZone(identifier: "Europe/Madrid")!
        )

        XCTAssertEqual(
            result,
            """
            UTC: 1970-01-01 00:00:00 GMT (1d 1h 1m 1s ago)
            Local: 1970-01-01 01:00:00 GMT+1 (1d 1h 1m 1s ago)
            """
        )
    }

    func testEpochSkipsTheLocalLineOnAUTCMachine() {
        let now = Date(timeIntervalSince1970: 90_061)
        let result = CommandTransformerEngine.formatUTCAndLocal(
            Date(timeIntervalSince1970: 0),
            now: now,
            localTimeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(result, "UTC: 1970-01-01 00:00:00 GMT (1d 1h 1m 1s ago)")
    }

    func testEpochSecondsAndMillisecondsBothReportUTC() {
        let now = Date(timeIntervalSince1970: 90_061)
        let seconds = CommandTransformerEngine.evaluate("0000000000", now: now)
            .first { $0.transformerName == "Epoch Seconds" }?.resultText
        let milliseconds = CommandTransformerEngine.evaluate("00000000000000", now: now)
            .first { $0.transformerName == "Epoch Milliseconds" }?.resultText

        for result in [seconds, milliseconds] {
            XCTAssertEqual(
                result?.split(separator: "\n").first.map(String.init),
                "UTC: 1970-01-01 00:00:00 GMT (1d 1h 1m 1s ago)"
            )
        }
    }

    func testByteConversionOutputsEveryOtherUnit() {
        let results = CommandTransformerEngine.evaluate("1024 bytes")

        let result = results.first { $0.transformerName == "Disk Size Units" }?.resultText
        XCTAssertEqual(
            result,
            """
            kb: 1
            mb: 0.000977
            gb: 0.000001
            tb: 0
            """
        )
    }

    func testByteConversionExcludesEnteredUnit() {
        let results = CommandTransformerEngine.evaluate("1 mb")

        let result = results.first { $0.transformerName == "Disk Size Units" }?.resultText
        XCTAssertEqual(
            result,
            """
            bytes: 1048576
            kb: 1024
            gb: 0.000977
            tb: 0.000001
            """
        )
    }

    func testByteConversionTreatsBAsBytesAlias() {
        let results = CommandTransformerEngine.evaluate("1024 b")

        let result = results.first { $0.transformerName == "Disk Size Units" }?.resultText
        XCTAssertEqual(
            result,
            """
            kb: 1
            mb: 0.000977
            gb: 0.000001
            tb: 0
            """
        )
    }

    func testByteConversionDoesNotMatchIncompleteUnitRegex() {
        let results = CommandTransformerEngine.evaluate("1024 m")

        XCTAssertFalse(results.contains { $0.transformerName == "Disk Size Units" })
    }

    /// Time zones moved into the catalog's Time group, so these cover the
    /// string prefix machinery with a transformer of their own.
    private var greetingTransformer: CommandTransformer {
        CommandTransformer(name: "Greeting", parts: [.string("hello world")]) { _, _ in
            "hi there"
        }
    }

    func testStringCommandRunsOnAFullMatch() {
        let results = CommandTransformerEngine.evaluate(
            "hello world",
            transformers: [greetingTransformer]
        )

        XCTAssertEqual(results.first?.transformerName, "Greeting")
        XCTAssertEqual(results.first?.resultText, "hi there")
    }

    func testStringCommandPrefixShowsTheRemainder() {
        let results = CommandTransformerEngine.evaluate(
            "hello w",
            transformers: [greetingTransformer]
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].displayText, "hello world")
        XCTAssertEqual(results[0].segments, [
            CommandDisplaySegment(text: "hello w", kind: .matched),
            CommandDisplaySegment(text: "orld", kind: .placeholder),
        ])
        XCTAssertEqual(results[0].resultText, "hi there")
    }

    func testStringCommandMatchesFromTheFirstLetter() {
        let results = CommandTransformerEngine.evaluate(
            "h",
            transformers: [greetingTransformer]
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].displayText, "hello world")
        XCTAssertEqual(results[0].resultText, "hi there")
    }

    func testCurrentTimeSupportsRequestedZones() {
        let now = Date(timeIntervalSince1970: 0)
        let zones = ["utc", "et", "cet", "turkey", "dubai", "korea", "japan"]

        for zone in zones {
            let results = CommandTransformerEngine.evaluate("\(zone) time", now: now)
            XCTAssertEqual(results.count, 1, "Expected \(zone) to match")
            XCTAssertNotNil(results[0].resultText)
        }
    }
}
