import XCTest
@testable import EditMD

// MARK: - Slow-keystroke breakdown formatting (TypingProfiler)

final class TypingProfilerTests: XCTestCase {

    func testBreakdownSortsHeaviestFirst() {
        let phases: [(name: StaticString, duration: Duration)] = [
            ("content", .milliseconds(1)),
            ("highlight", .milliseconds(9)),
            ("stats", .milliseconds(4)),
        ]
        XCTAssertEqual(slowKeystrokeBreakdown(phases),
                       "highlight=9.0ms stats=4.0ms content=1.0ms")
    }

    func testBreakdownCapsAtLimit() {
        let phases: [(name: StaticString, duration: Duration)] = [
            ("a", .milliseconds(5)),
            ("b", .milliseconds(4)),
            ("c", .milliseconds(3)),
            ("d", .milliseconds(2)),
            ("e", .milliseconds(1)),
        ]
        XCTAssertEqual(slowKeystrokeBreakdown(phases, limit: 2), "a=5.0ms b=4.0ms")
    }

    func testBreakdownEmpty() {
        XCTAssertEqual(slowKeystrokeBreakdown([]), "")
    }

    func testDurationMilliseconds() {
        XCTAssertEqual(Duration.milliseconds(16).milliseconds, 16, accuracy: 0.001)
        XCTAssertEqual(Duration.microseconds(500).milliseconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(Duration.seconds(2).milliseconds, 2000, accuracy: 0.001)
    }
}
