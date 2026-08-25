import XCTest
@testable import EditMD

/// The core library is linked in and answers.
///
/// A build gate already compares the vendored *header* against a frozen value
/// before anything compiles; this asks the *library*, through the wrapper the
/// app will actually use. The two can disagree — a header copied next to a
/// mismatched archive is exactly the case worth catching — and only this half
/// runs the code.
final class PDMCoreTests: XCTestCase {

    func testTheLinkedCoreSpeaksTheExpectedABI() {
        XCTAssertEqual(PDMCore.abiVersion(), 2)
    }

    func testTheWrapperAcceptsTheLinkedCore() {
        XCTAssertNoThrow(try PDMCore.checkABI())
    }

    func testAMismatchIsDistinguishableByCase() {
        let error = PDMCore.CoreError.abiMismatch(found: 3, expected: 2)
        XCTAssertEqual(error, .abiMismatch(found: 3, expected: 2))
        XCTAssertNotEqual(error, .abiMismatch(found: 2, expected: 2))
        XCTAssertEqual(error.description, "PrintDotMD ABI 3, expected 2")
    }
}
