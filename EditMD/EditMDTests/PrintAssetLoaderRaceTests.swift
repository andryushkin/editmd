import XCTest
@testable import EditMD

/// The path that is checked has to be the file that is read.
///
/// `bytes(forAssetNamed:)` used to touch the file system three times: resolve
/// and compare the path, stat the path, read the path. Between the first and
/// the third the name can be pointed somewhere else, and then the bytes that
/// come back are bytes the containment check never saw.
///
/// **Why this is a race probe and not a stationary one.** A deterministic
/// barrier cannot be built from outside: all three touches use the *already
/// resolved* path, so there is no component left to swap that the loader has
/// not already folded away — only the final file itself, and replacing it is
/// by definition a race with the reader. The probe therefore reports the
/// number of attempts, and the numbers are in the journal rather than a claim
/// that the window is gone.
final class PrintAssetLoaderRaceTests: XCTestCase {

    private struct Rig {
        let root: URL
        let doc: URL
        let asset: URL
        let realCopy: URL
        let linkCopy: URL
        let secret: Data
    }

    /// A folder with a real picture in it, an outside file, and the two forms
    /// of the asset name staged for swapping: `rename` is atomic, so the loader
    /// always sees one or the other and never a half-made file.
    private func makeRig() throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-race-\(UUID().uuidString)")
        let doc = root.appendingPathComponent("doc")
        try FileManager.default.createDirectory(at: doc, withIntermediateDirectories: true)

        // A real PNG: the loader hands `png` bytes over untouched, so whatever
        // comes back is what was on disk.
        let real = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(count: 64)
        let secret = Data("OUTSIDE-SECRET-BYTES-THAT-MUST-NEVER-BE-READ".utf8)

        let outside = root.appendingPathComponent("secret.png")
        try secret.write(to: outside)

        let asset = doc.appendingPathComponent("pic.png")
        let realCopy = doc.appendingPathComponent(".real.png")
        let linkCopy = doc.appendingPathComponent(".link.png")
        try real.write(to: realCopy)
        try real.write(to: asset)
        try FileManager.default.createSymbolicLink(at: linkCopy, withDestinationURL: outside)

        return Rig(root: root, doc: doc, asset: asset,
                   realCopy: realCopy, linkCopy: linkCopy, secret: secret)
    }

    /// Runs the loader against a name whose file is being flipped between a
    /// real picture and a link out of the folder, and reports how many attempts
    /// it took to read the outside bytes — or that it never did.
    private func attemptsUntilEscape(budget: Int) throws -> (escapes: Int, attempts: Int) {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let loader = PrintAssetLoader(baseDir: rig.doc)

        let stop = ManagedAtomicFlag()
        let flipper = Thread {
            var useLink = true
            while !stop.isSet {
                let source = useLink ? rig.linkCopy : rig.realCopy
                let staged = rig.doc.appendingPathComponent("staged.png")
                try? FileManager.default.removeItem(at: staged)
                if useLink,
                   let target = try? FileManager.default
                    .destinationOfSymbolicLink(atPath: rig.linkCopy.path) {
                    try? FileManager.default.createSymbolicLink(
                        atPath: staged.path, withDestinationPath: target)
                } else {
                    try? FileManager.default.copyItem(at: source, to: staged)
                }
                _ = staged.withUnsafeFileSystemRepresentation { from in
                    rig.asset.withUnsafeFileSystemRepresentation { to in
                        rename(from!, to!)
                    }
                }
                useLink.toggle()
            }
        }
        flipper.start()
        defer { stop.set() }

        var escapes = 0
        var attempts = 0
        while attempts < budget {
            attempts += 1
            if let data = loader.bytes(forAssetNamed: "pic.png"), data == rig.secret {
                escapes += 1
                break
            }
        }
        return (escapes, attempts)
    }

    /// The measurement. Recorded rather than asserted in the "before" state,
    /// asserted once the loader reads what it checked.
    ///
    /// The budget is 50 000 rather than the 200 000 the repair was measured
    /// against, because it is paid on every run of the suite: before the
    /// repair the escape came on attempt **36**, so fifty thousand is over a
    /// thousand times the distance the defect needed, and the longer run is
    /// recorded in the journal instead of in everybody's build.
    func testTheLoaderNeverReadsBytesFromOutsideTheFolder() throws {
        let (escapes, attempts) = try attemptsUntilEscape(budget: 50_000)
        print("AUDIT race: escapes=\(escapes) after \(attempts) attempts")
        XCTAssertEqual(escapes, 0,
                       "read bytes from outside the document's folder after \(attempts) attempts")
    }

    /// The stationary refusals the loader already makes, kept here beside the
    /// race so a repair cannot buy the window by breaking them.
    func testTheStationaryRefusalsStillHold() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let loader = PrintAssetLoader(baseDir: rig.doc)

        XCTAssertNotNil(loader.bytes(forAssetNamed: "pic.png"), "the ordinary case")
        XCTAssertNotNil(loader.bytes(forAssetNamed: "sub/../pic.png"),
                        "a legal `..` inside the folder is still legal")
        XCTAssertNil(loader.bytes(forAssetNamed: "../secret.png"))
        XCTAssertNil(loader.bytes(forAssetNamed: "/etc/passwd"))
        XCTAssertNil(loader.bytes(forAssetNamed: "~/secret.png"))
        XCTAssertNil(loader.bytes(forAssetNamed: ".link.png"),
                     "a link inside the folder that leads out of it")
        XCTAssertNil(loader.bytes(forAssetNamed: "."))
    }
}

/// A flag two threads can share without pulling in a dependency.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
