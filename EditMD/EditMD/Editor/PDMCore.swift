import Foundation
import OSLog
import PrintDotMD

/// The app's whole view of the prebuilt core library: a thin wrapper over the
/// C ABI, not a re-modelling of it. Everything the app is allowed to know
/// about the core enters here, so the C names stay in one file and the rest of
/// the app talks Swift.
///
/// Today it answers exactly one question — which contract the linked library
/// speaks. Printing itself is not wired yet; when it is, it arrives as one
/// input type handed to one call, and this stays the only importer of the
/// module.
enum PDMCore {

    /// The contract this app was written against.
    ///
    /// A Swift literal on purpose. The header ships *inside* the artifact and
    /// clang imports `PDM_ABI_VERSION` into Swift as a constant, so writing
    /// `PDM_ABI_VERSION` here would compare the vendored library against its
    /// own header: a core built with a different version would move both sides
    /// of the comparison at once and the check could never fail. The literal
    /// lives in the app's own tree and moves only when a human moves it —
    /// together with `abi_version` in `Vendor/core.expected.json`.
    static let expectedABIVersion: UInt32 = 2

    /// The contract the linked library speaks. Reads it from the library, not
    /// from the header: this is the value the build gate cannot see.
    static func abiVersion() -> UInt32 {
        pdm_abi_version()
    }

    /// Why the core cannot be used. Distinguishable by case, not by a string,
    /// so a caller can tell "wrong core" from whatever failures printing will
    /// add later.
    enum CoreError: Error, Equatable, CustomStringConvertible {
        /// The linked library speaks a different contract than this app.
        case abiMismatch(found: UInt32, expected: UInt32)

        var description: String {
            switch self {
            case let .abiMismatch(found, expected):
                return "PrintDotMD ABI \(found), expected \(expected)"
            }
        }
    }

    /// Refuses when the linked library speaks a contract this app does not.
    ///
    /// `scripts/verify-core.sh` catches the same mismatch before the build
    /// starts, from the vendored header. This is the runtime half of the pair:
    /// the gate reads a file next to the library, this reads the library.
    static func checkABI() throws {
        let found = abiVersion()
        guard found == expectedABIVersion else {
            throw CoreError.abiMismatch(found: found, expected: expectedABIVersion)
        }
    }

    private static let log = Logger(subsystem: "andryushkin.EditMD", category: "core")

    /// Called once at launch. Two jobs, and the second is not incidental: it
    /// says out loud which core the app is running, and it is the app's only
    /// reference to the library, so it is what keeps the core linked into a
    /// Release binary at all — the linker drops archive members nothing
    /// reaches.
    static func reportABI() {
        do {
            try checkABI()
            log.info("PrintDotMD ABI \(abiVersion(), privacy: .public)")
        } catch {
            log.error("PrintDotMD core refused: \(String(describing: error), privacy: .public)")
            // A build mistake, not a user's problem: the vendored library and
            // this app were built against different contracts. Loud in debug,
            // logged in release — the app itself still runs, it just has no
            // core to call.
            assertionFailure("\(error)")
        }
    }
}
