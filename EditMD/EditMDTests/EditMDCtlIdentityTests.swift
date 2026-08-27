import XCTest
@testable import EditMD

/// `editmdctl --version` names the build it came from.
///
/// The probe runs the real product, not a function inside the app: the answer is
/// assembled by a target of its own out of an embedded `Info.plist`, and a unit
/// test of a Swift function would not have gone near either. What it compares
/// against is the **host app's** own identity, read at runtime from its bundle —
/// two products of one build, asked separately, have to give the same answer.
/// That is the statement R-09 is about, and it is why the expected value is not
/// a literal repeated here.
///
/// Every field is checked by name and reported by name. A probe that only looked
/// at the exit status would stay green with every field wrong, which is the
/// failure this file exists to make impossible.
final class EditMDCtlIdentityTests: XCTestCase {

    /// The built CLI.
    ///
    /// Two places, because there are two: `xcodebuild` leaves it beside the host
    /// app in the products directory, and `scripts/dist.sh` copies it into
    /// `Contents/MacOS` of the app it packages. Whichever run this is, the
    /// binary being asked is the one that run produced.
    ///
    /// Missing is a **failure and never a skip**: the scheme builds `editmdctl`
    /// for every action, so its absence means the run is not the run it claims
    /// to be — and a probe that quietly passes when its subject is not there is
    /// worse than no probe.
    private func editmdctlURL() throws -> URL {
        let app = Bundle.main.bundleURL
        let candidates = [
            app.deletingLastPathComponent().appendingPathComponent("editmdctl"),
            app.appendingPathComponent("Contents/MacOS/editmdctl"),
        ]
        guard let tool = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw Missing(paths: candidates.map(\.path))
        }
        return tool
    }

    /// Not `XCTSkip`: a skipped test reads as "nothing to worry about" in a
    /// log nobody scrolls, and the thing being reported is that the product
    /// under test was not built.
    private struct Missing: Error, CustomStringConvertible {
        let paths: [String]
        var description: String {
            "editmdctl was not built; looked in \(paths.joined(separator: ", "))"
        }
    }

    private func run(_ arguments: [String]) throws -> (out: String, status: Int32) {
        let process = Process()
        process.executableURL = try editmdctlURL()
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    /// `key=value key=value` on one line, as the command prints it.
    private func fields(_ line: String) -> [String: String] {
        var parsed: [String: String] = [:]
        for token in line.split(separator: " ") {
            let halves = token.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { continue }
            parsed[String(halves[0])] = String(halves[1])
        }
        return parsed
    }

    func testTheCommandNamesTheSameBuildAsTheApp() throws {
        let expectedVersion = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            "the test host has no version to compare against")
        let expectedBuild = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            "the test host has no build number to compare against")

        let (output, status) = try run(["--version"])
        XCTAssertEqual(status, 0, "editmdctl --version exited \(status): \(output)")

        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(line.hasPrefix("editmdctl "),
                      "the line has to name the tool it identifies: \(line)")

        let printed = fields(line)
        XCTAssertEqual(printed["version"], expectedVersion,
                       "field `version` — the CLI and the app name different builds")
        XCTAssertEqual(printed["build"], expectedBuild,
                       "field `build` — the CLI and the app name different builds")
        XCTAssertEqual(Set(printed.keys), ["version", "build"],
                       "the fields of the line are the fields the probe knows")
    }

    /// The same three facts as an object, for whoever parses rather than reads.
    func testTheJSONFormCarriesTheSameFields() throws {
        let (line, status) = try run(["--version"])
        let (jsonOut, jsonStatus) = try run(["--json", "--version"])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(jsonStatus, 0)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(jsonOut.utf8)) as? [String: String],
            "--json --version did not print an object of strings: \(jsonOut)")
        let printed = fields(line.trimmingCharacters(in: .whitespacesAndNewlines))

        XCTAssertEqual(object["tool"], "editmdctl", "field `tool`")
        XCTAssertEqual(object["version"], printed["version"], "field `version`")
        XCTAssertEqual(object["build"], printed["build"], "field `build`")
    }

    /// The core is not named here, and that is the measured answer rather than
    /// an omission: this target links no core at all (`nm -u` finds zero `pdm_`
    /// symbols in it), so a field about the page renderer's contract would be a
    /// claim about a library the binary never loads. The app answers that one.
    func testTheCommandClaimsNothingAboutTheCore() throws {
        let (output, _) = try run(["--json", "--version"])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        XCTAssertNil(object["abi"], "field `abi` — editmdctl cannot honestly answer this")
        XCTAssertNil(object["core"], "field `core` — editmdctl cannot honestly answer this")
    }
}
