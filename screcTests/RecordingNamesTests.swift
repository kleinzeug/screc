import XCTest

final class RecordingNamesTests: XCTestCase {
    // 2026-07-29 12:34:56 UTC
    private let now = Date(timeIntervalSince1970: 1_785_328_496)
    private let utc = TimeZone(identifier: "UTC")!

    func testTokensExpand() {
        XCTAssertEqual(
            RecordingNames.make(pattern: "screc-{date}-{time}", now: now, timeZone: utc),
            "screc-20260729-123456")
    }

    func testPathHostileCharactersSanitized() {
        XCTAssertEqual(
            RecordingNames.make(pattern: "a/b:c", now: now, timeZone: utc),
            "a-b-c")
    }

    func testEmptyPatternFallsBack() {
        XCTAssertEqual(
            RecordingNames.make(pattern: "   ", now: now, timeZone: utc),
            "screc-20260729-123456")
    }

    func testDigitsAreASCIIRegardlessOfPattern() {
        // The formatter locale is pinned to en_US_POSIX; whatever the host
        // locale, expanded tokens must be plain ASCII digits.
        let name = RecordingNames.make(pattern: "{date}{time}", now: now, timeZone: utc)
        XCTAssertTrue(name.allSatisfy { $0.isASCII })
        XCTAssertEqual(name, "20260729123456")
    }
}
