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

    /// One verdict, and everything that calls the core reads it.
    ///
    /// Green here says the vendored library is in range. Under a core that is
    /// not — the R-09 planting — this is the probe that says so *and says which
    /// contract was found*, and it says it in a Release build too: the verdict
    /// is a stored value, not an `assertionFailure`, and an assertion is
    /// compiled out of a shipping build entirely. Before this, a Release app
    /// with a foreign core started in silence and kept the news until somebody
    /// printed.
    func testTheOneVerdictIsWhatTheAppRefusesOn() {
        switch PDMCore.contract {
        case .success(let version):
            XCTAssertEqual(version, PDMCore.expectedABIVersion)
            XCTAssertEqual(version, PDMCore.abiVersion(),
                           "the verdict is about the library, not about a literal")
        case .failure(let mismatch):
            XCTFail("the linked core is outside the range: \(mismatch)")
        }
    }

    func testAMismatchIsDistinguishableByCase() {
        let error = PDMCore.CoreError.abiMismatch(found: 3, expected: 2)
        XCTAssertEqual(error, .abiMismatch(found: 3, expected: 2))
        XCTAssertNotEqual(error, .abiMismatch(found: 2, expected: 2))
        XCTAssertEqual(error.description, "PrintDotMD ABI 3, expected 2")
    }
}
