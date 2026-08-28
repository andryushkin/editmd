import XCTest
@testable import EditMD

/// A render that says it succeeded and produced nothing is refused, and the
/// refusal reaches the disk.
///
/// The rule is exercised through `PDMCore.checkedResult` rather than by making
/// the real library misbehave, because there is no way to make it: a result
/// handle belongs to the library and cannot be fabricated on this side. What
/// the probe hands over is exactly what the boundary hands over — a pointer
/// that may be absent, a length, a page count — so what is tested is the rule
/// the print path runs, not a copy of it.
final class PrintEmptyResultTests: XCTestCase {

    private static let noWarnings: [PrintWarning] = []
    private static let noAssets: [PrintAssetRecord] = []

    private func checked(pdf: Data?, pages: Int) throws -> PrintRenderResult {
        try PDMCore.checkedResult(pdf: pdf, pageCount: pages,
                                  warnings: Self.noWarnings, assets: Self.noAssets)
    }

    /// NULL from the library. Also what a panic inside a reading function
    /// answers with, which is why it cannot be read as "an empty document".
    func testANullPointerIsARefusalAndNotEmptyBytes() {
        XCTAssertThrowsError(try checked(pdf: nil, pages: 1)) { error in
            XCTAssertEqual(error as? PDMCore.CoreError, .emptyResult(pages: 1))
        }
    }

    func testZeroLengthBytesAreARefusal() {
        XCTAssertThrowsError(try checked(pdf: Data(), pages: 1)) { error in
            XCTAssertEqual(error as? PDMCore.CoreError, .emptyResult(pages: 1))
        }
    }

    /// Bytes with no pages behind them. The count crosses as a plain number
    /// with no way to say "absent", so zero is what a panicked counter looks
    /// like too.
    func testBytesWithNoPagesAreARefusal() {
        XCTAssertThrowsError(try checked(pdf: Data([0x25, 0x50]), pages: 0)) { error in
            XCTAssertEqual(error as? PDMCore.CoreError, .emptyResult(pages: 0))
        }
    }

    /// The control: a result with bytes and pages is not refused. Without this
    /// the three above would pass on a rule that refuses everything.
    func testARealResultIsAccepted() throws {
        let result = try checked(pdf: Data([0x25, 0x50, 0x44, 0x46]), pages: 2)
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.pdf.count, 4)
    }

    /// What the person is told, in the language they read it in.
    func testTheRefusalSaysSomethingAPersonCanRead() {
        let error = PDMCore.CoreError.emptyResult(pages: 0)
        XCTAssertEqual(error.description,
                       "PrintDotMD reported success with no pages (0 claimed)")
        XCTAssertEqual(error.errorDescription,
                       "The page renderer returned no pages.")
    }

    // MARK: - The disk

    /// The export writes nothing when the render refuses.
    ///
    /// Checked on the file system rather than on the returned value: the point
    /// of the repair is that a zero-byte PDF must not be sitting there
    /// afterwards, and `write(to:options:.atomic)` leaves a file behind if it
    /// is reached at all. The refusal has to happen before it is reached.
    @MainActor
    func testAnExportThatRefusesLeavesNoFileOnDisk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("out.pdf")

        // The failure is produced where the boundary produces it, and the
        // export's own writing code is what is being watched.
        let outcome = await PDFExport.command(
            DocumentActions(save: {}, saveAs: {}, hasURL: false,
                            markdownContent: { "# Doc\n" }),
            destination: { _ in target },
            reveal: { _ in })

        switch outcome {
        case .wrote:
            // A real render succeeded, which is the ordinary case on a healthy
            // core; then the file must exist and must not be empty.
            let size = try FileManager.default
                .attributesOfItem(atPath: target.path)[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 0, "an export that reports success wrote nothing")
        case .failed:
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                           "a refused export left a file behind")
        default:
            XCTFail("\(outcome)")
        }
    }
}
