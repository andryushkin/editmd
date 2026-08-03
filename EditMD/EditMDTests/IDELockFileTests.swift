import XCTest
@testable import EditMD

/// The lock file IS the discovery mechanism. Wrong schema, wrong
/// permissions or a stale file and `/ide` either finds nothing or dials a dead
/// port. All tests run against an injected directory — never `~/.claude/ide`.
final class IDELockFileTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-ide-lock-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    // MARK: - Auth token

    func testAuthTokenIs32LowercaseHexChars() throws {
        let token = try IDELockFile.generateAuthToken()
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testAuthTokensDiffer() throws {
        let a = try IDELockFile.generateAuthToken()
        let b = try IDELockFile.generateAuthToken()
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Write / read

    func testWriteThenReadRoundTrips() throws {
        let contents = IDELockFileContents(pid: 4242,
                                           workspaceFolders: ["/tmp/notes", "/tmp/other"],
                                           authToken: "abc123")
        try IDELockFile.write(contents, port: 51234, in: directory)
        XCTAssertEqual(try IDELockFile.read(port: 51234, in: directory), contents)
    }

    /// Field names and values are the contract with the CLI — assert the raw JSON.
    func testOnDiskSchemaMatchesTheSpec() throws {
        let contents = IDELockFileContents(pid: 99,
                                           workspaceFolders: ["/tmp/notes"],
                                           authToken: "deadbeef")
        let url = try IDELockFile.write(contents, port: 40000, in: directory)
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(raw["pid"] as? Int, 99)
        XCTAssertEqual(raw["ideName"] as? String, "EditMD")
        XCTAssertEqual(raw["transport"] as? String, "ws")
        XCTAssertEqual(raw["authToken"] as? String, "deadbeef")
        XCTAssertEqual(raw["workspaceFolders"] as? [String], ["/tmp/notes"])
        XCTAssertEqual(Set(raw.keys),
                       ["pid", "workspaceFolders", "ideName", "transport", "authToken"])
    }

    func testFileNameIsPortDotLock() throws {
        try IDELockFile.write(
            IDELockFileContents(workspaceFolders: [], authToken: "t"), port: 12345, in: directory)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("12345.lock").path))
    }

    // MARK: - Permissions

    func testDirectoryIs0700AndFileIs0600() throws {
        let url = try IDELockFile.write(
            IDELockFileContents(workspaceFolders: [], authToken: "t"), port: 40001, in: directory)
        XCTAssertEqual(try permissions(of: url), 0o600)
        XCTAssertEqual(try permissions(of: directory), 0o700)
    }

    /// The token leaks if a rewrite inherits a loose mode from an earlier file.
    func testRewriteTightensPermissions() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("40002.lock")
        FileManager.default.createFile(atPath: target.path, contents: Data("{}".utf8),
                                       attributes: [.posixPermissions: 0o644])
        try IDELockFile.write(
            IDELockFileContents(workspaceFolders: [], authToken: "t"), port: 40002, in: directory)
        XCTAssertEqual(try permissions(of: target), 0o600)
    }

    func testWriteTightensLooseDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try IDELockFile.write(
            IDELockFileContents(workspaceFolders: [], authToken: "t"), port: 40003, in: directory)
        XCTAssertEqual(try permissions(of: directory), 0o700)
    }

    // MARK: - Stale cleanup

    func testProcessIsAliveForSelfAndNotForBogusPID() {
        XCTAssertTrue(IDELockFile.processIsAlive(ProcessInfo.processInfo.processIdentifier))
        // PID 0 is the kernel scheduler; `kill(0, …)` addresses the process
        // group, so it must be treated as "not a real lock owner".
        XCTAssertFalse(IDELockFile.processIsAlive(0))
        XCTAssertFalse(IDELockFile.processIsAlive(Int32.max))
    }

    func testCleanStaleRemovesDeadPIDsAndKeepsLive() throws {
        let live = ProcessInfo.processInfo.processIdentifier
        try IDELockFile.write(IDELockFileContents(pid: live, workspaceFolders: [], authToken: "a"),
                              port: 40010, in: directory)
        try IDELockFile.write(IDELockFileContents(pid: Int32.max, workspaceFolders: [], authToken: "b"),
                              port: 40011, in: directory)

        let removed = IDELockFile.cleanStale(in: directory)

        XCTAssertEqual(removed.map(\.lastPathComponent), ["40011.lock"])
        XCTAssertNoThrow(try IDELockFile.read(port: 40010, in: directory))
        XCTAssertThrowsError(try IDELockFile.read(port: 40011, in: directory))
    }

    /// A lock file from another editor's future schema must survive us.
    func testCleanStaleIgnoresUnparseableFiles() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let alien = directory.appendingPathComponent("40020.lock")
        try Data(#"{"someOtherSchema":1}"#.utf8).write(to: alien)

        XCTAssertTrue(IDELockFile.cleanStale(in: directory).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: alien.path))
    }

    func testCleanStaleOnMissingDirectoryIsNoop() {
        XCTAssertTrue(IDELockFile.cleanStale(in: directory).isEmpty)
    }

    func testRemoveDeletesTheFile() throws {
        try IDELockFile.write(IDELockFileContents(workspaceFolders: [], authToken: "t"),
                              port: 40030, in: directory)
        IDELockFile.remove(port: 40030, in: directory)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("40030.lock").path))
    }
}
