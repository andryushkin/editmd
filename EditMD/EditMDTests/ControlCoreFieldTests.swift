import XCTest
@testable import EditMD

/// `status` answers about the core the app links.
///
/// Two probes, and the second is the reason there are two: the first can only
/// ever see the library that is actually installed, which is a healthy one, so
/// on its own it would test the shape of a success and call the mismatch path
/// covered. The second hands the field an artificial verdict.
final class ControlCoreFieldTests: XCTestCase {

    private func fields(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let object)? = value else {
            throw XCTSkip("not an object: \(String(describing: value))")
        }
        return object
    }

    /// The exact shape, on the verdict the linked library actually produces.
    @MainActor
    func testStatusCarriesTheCoreItLinks() throws {
        let response = ControlRouter.process(ControlRequest(id: "1", cmd: "status"))
        XCTAssertTrue(response.ok, response.error ?? "")
        let object = try fields(response.data)
        let core = try fields(object["core"])

        XCTAssertEqual(Set(core.keys), ["abi", "expected", "verdict"],
                       "the object is a contract; a new key is a wire change")
        XCTAssertEqual(core["expected"], .int(Int(PDMCore.expectedABIVersion)))
        XCTAssertEqual(core["abi"], .int(Int(PDMCore.abiVersion())),
                       "the number must come from the library, not from a literal")
        XCTAssertEqual(core["verdict"], .string("ok"),
                       "the installed core is the one this app was built for")
    }

    /// A core this app does not speak — the case the installed library can
    /// never show. The verdict is handed in, so the field is exercised without
    /// a foreign library anywhere near the machine.
    func testAMismatchIsReportedAsItsOwnToken() throws {
        let field = ControlRouter.coreField(
            .failure(.abiMismatch(found: 3, expected: 2)), expected: 2)
        let core = try fields(field)
        XCTAssertEqual(core["abi"], .int(3), "the number the foreign library gave")
        XCTAssertEqual(core["expected"], .int(2))
        XCTAssertEqual(core["verdict"], .string("abi-mismatch"))
    }

    /// A verdict this side cannot name must not read as a working core.
    func testAVerdictWithNoNameIsNotOk() throws {
        let core = try fields(ControlRouter.coreField(.failure(.documentRejected),
                                                      expected: 2))
        XCTAssertEqual(core["verdict"], .string("unusable"))
        XCTAssertNotEqual(core["verdict"], .string("ok"))
    }

    /// The token is a token. A localized string here would be the one form a
    /// script cannot compare, and the other two forms already exist.
    func testTheVerdictIsNotLocalized() throws {
        for verdict in ["ok", "abi-mismatch", "unusable"] {
            XCTAssertEqual(String(localized: String.LocalizationValue(verdict)), verdict,
                           "the catalog must not carry a translation for \(verdict)")
        }
    }
}
