import XCTest
@testable import EditMD

/// The 12 tools against a fake editor. The response *shape* is
/// the contract with a CLI we cannot patch — assert the JSON, not just the
/// Swift values. Also covers the edge cases the CLI hits in practice: no
/// selection, file not open, file outside the workspace.
final class ClaudeIDEToolsTests: XCTestCase {

    private var context: FakeEditorContext!
    private var tools: ClaudeIDETools!

    override func setUp() {
        context = FakeEditorContext()
        tools = ClaudeIDETools(context: context)
    }

    // MARK: - Helpers

    /// Unwraps `{"content":[{"type":"text","text":"<json>"}]}` → parsed JSON.
    private func payload(_ result: Result<JSONValue, RPCError>) throws -> [String: Any] {
        let text = try textItem(result)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func payloadArray(_ result: Result<JSONValue, RPCError>) throws -> [[String: Any]] {
        let text = try textItem(result)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    }

    private func textItem(_ result: Result<JSONValue, RPCError>) throws -> String {
        let value = try result.get()
        let content = try XCTUnwrap(value["content"]?.arrayValue)
        return try XCTUnwrap(content.first?["text"]?.stringValue)
    }

    private func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async
        -> Result<JSONValue, RPCError> {
        await tools.call(name: name, arguments: .object(arguments))
    }

    // MARK: - Selection

    func testGetCurrentSelectionReturnsPositionsAndFileURL() async throws {
        context.current = IDESelection(
            text: "world",
            filePath: "/tmp/note.md",
            range: IDESelectionRange(start: IDEPosition(line: 1, character: 6),
                                     end: IDEPosition(line: 1, character: 11)))

        let json = try payload(await call("getCurrentSelection"))

        XCTAssertEqual(json["success"] as? Bool, true)
        XCTAssertEqual(json["text"] as? String, "world")
        XCTAssertEqual(json["filePath"] as? String, "/tmp/note.md")
        XCTAssertEqual(json["fileUrl"] as? String, "file:///tmp/note.md")
        let selection = try XCTUnwrap(json["selection"] as? [String: Any])
        XCTAssertEqual(selection["isEmpty"] as? Bool, false)
        let start = try XCTUnwrap(selection["start"] as? [String: Any])
        XCTAssertEqual(start["line"] as? Int, 1)
        XCTAssertEqual(start["character"] as? Int, 6)
    }

    func testGetCurrentSelectionWithNoEditorSaysSoInsteadOfFailing() async throws {
        context.current = nil
        let json = try payload(await call("getCurrentSelection"))
        XCTAssertEqual(json["success"] as? Bool, false)
        XCTAssertNotNil(json["message"])
    }

    func testEmptySelectionIsReportedAsEmpty() async throws {
        let caret = IDEPosition(line: 3, character: 0)
        context.current = IDESelection(text: "", filePath: "/tmp/a.md",
                                       range: IDESelectionRange(start: caret, end: caret))
        let json = try payload(await call("getCurrentSelection"))
        let selection = try XCTUnwrap(json["selection"] as? [String: Any])
        XCTAssertEqual(selection["isEmpty"] as? Bool, true)
    }

    func testGetLatestSelectionSurvivesAnEmptyCurrentOne() async throws {
        context.current = nil
        context.latest = IDESelection(
            text: "kept",
            filePath: "/tmp/a.md",
            range: IDESelectionRange(start: IDEPosition(line: 0, character: 0),
                                     end: IDEPosition(line: 0, character: 4)))
        let json = try payload(await call("getLatestSelection"))
        XCTAssertEqual(json["text"] as? String, "kept")
    }

    // MARK: - Editors / workspace

    func testGetOpenEditorsReportsActiveAndDirty() async throws {
        context.editors = [
            IDEEditorTab(path: "/tmp/a.md", isActive: true, isDirty: true),
            IDEEditorTab(path: "/tmp/sub/b.md", isActive: false, isDirty: false),
        ]
        let json = try payload(await call("getOpenEditors"))
        let tabs = try XCTUnwrap(json["tabs"] as? [[String: Any]])
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(tabs[0]["uri"] as? String, "file:///tmp/a.md")
        XCTAssertEqual(tabs[0]["label"] as? String, "a.md")
        XCTAssertEqual(tabs[0]["languageId"] as? String, "markdown")
        XCTAssertEqual(tabs[0]["isActive"] as? Bool, true)
        XCTAssertEqual(tabs[0]["isDirty"] as? Bool, true)
        XCTAssertEqual(tabs[1]["isActive"] as? Bool, false)
    }

    func testGetWorkspaceFoldersUsesFirstAsRootPath() async throws {
        context.folders = [IDEWorkspaceFolder(path: "/tmp/notes"),
                           IDEWorkspaceFolder(path: "/tmp/other")]
        let json = try payload(await call("getWorkspaceFolders"))
        XCTAssertEqual(json["rootPath"] as? String, "/tmp/notes")
        let folders = try XCTUnwrap(json["folders"] as? [[String: Any]])
        XCTAssertEqual(folders[0]["name"] as? String, "notes")
        XCTAssertEqual(folders[0]["path"] as? String, "/tmp/notes")
        XCTAssertEqual(folders[0]["uri"] as? String, "file:///tmp/notes/")
    }

    func testGetWorkspaceFoldersWithNoneHasNullRoot() async throws {
        context.folders = []
        let json = try payload(await call("getWorkspaceFolders"))
        XCTAssertTrue(json["rootPath"] is NSNull)
    }

    // MARK: - openFile

    func testOpenFilePassesThroughAllArguments() async throws {
        let json = try payload(await call("openFile", [
            "filePath": .string("/tmp/a.md"),
            "startText": .string("Hello"),
            "endText": .string("world"),
            "selectToEndOfLine": .bool(true),
            "makeFrontmost": .bool(false),
        ]))
        XCTAssertEqual(json["success"] as? Bool, true)
        XCTAssertEqual(context.openedFile?.filePath, "/tmp/a.md")
        XCTAssertEqual(context.openedFile?.startText, "Hello")
        XCTAssertEqual(context.openedFile?.endText, "world")
        XCTAssertEqual(context.openedFile?.selectToEndOfLine, true)
        XCTAssertEqual(context.openedFile?.makeFrontmost, false)
    }

    func testOpenFileWithoutPathIsAnInvalidParamsError() async {
        let result = await call("openFile")
        guard case .failure(let error) = result else { return XCTFail("Expected failure") }
        XCTAssertEqual(error.code, RPCError.invalidParams)
    }

    func testOpenFileDefaultsMakeFrontmostToTrue() async throws {
        _ = try payload(await call("openFile", ["filePath": .string("/tmp/a.md")]))
        XCTAssertEqual(context.openedFile?.makeFrontmost, true)
    }

    // MARK: - Dirty / save

    func testCheckDocumentDirtyForOpenFile() async throws {
        context.dirtyStates["/tmp/a.md"] = IDEDirtyState(isDirty: true, isUntitled: false)
        let json = try payload(await call("checkDocumentDirty",
                                          ["filePath": .string("/tmp/a.md")]))
        XCTAssertEqual(json["success"] as? Bool, true)
        XCTAssertEqual(json["isDirty"] as? Bool, true)
        XCTAssertEqual(json["isUntitled"] as? Bool, false)
    }

    func testCheckDocumentDirtyForClosedFileReportsNotOpen() async throws {
        let json = try payload(await call("checkDocumentDirty",
                                          ["filePath": .string("/tmp/not-open.md")]))
        XCTAssertEqual(json["success"] as? Bool, false)
        XCTAssertNil(json["isDirty"])
    }

    func testSaveDocumentSucceedsOnlyForOpenFiles() async throws {
        context.savableFiles = ["/tmp/a.md"]
        let open = try payload(await call("saveDocument", ["filePath": .string("/tmp/a.md")]))
        XCTAssertEqual(open["success"] as? Bool, true)
        let closed = try payload(await call("saveDocument", ["filePath": .string("/tmp/b.md")]))
        XCTAssertEqual(closed["success"] as? Bool, false)
    }

    // MARK: - getDiagnostics (our lint — not an empty array like Obsidian)

    func testGetDiagnosticsMapsLintToLSPShape() async throws {
        context.diagnosticFiles = [IDEDiagnosticFile(
            uri: "file:///tmp/a.md",
            diagnostics: [IDEDiagnostic(
                message: "Empty checkbox “[]” — needs a space or x inside",
                severity: "Error",
                source: "editmd-lint",
                code: "emptyCheckbox",
                range: IDESelectionRange(start: IDEPosition(line: 2, character: 2),
                                         end: IDEPosition(line: 2, character: 4)))])]

        let files = try payloadArray(await call("getDiagnostics"))

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0]["uri"] as? String, "file:///tmp/a.md")
        let diagnostics = try XCTUnwrap(files[0]["diagnostics"] as? [[String: Any]])
        XCTAssertEqual(diagnostics[0]["severity"] as? String, "Error")
        XCTAssertEqual(diagnostics[0]["source"] as? String, "editmd-lint")
        XCTAssertEqual(diagnostics[0]["code"] as? String, "emptyCheckbox")
        let range = try XCTUnwrap(diagnostics[0]["range"] as? [String: Any])
        let start = try XCTUnwrap(range["start"] as? [String: Any])
        XCTAssertEqual(start["line"] as? Int, 2)
    }

    func testGetDiagnosticsPassesURIThrough() async throws {
        _ = try payloadArray(await call("getDiagnostics",
                                        ["uri": .string("file:///tmp/b.md")]))
        XCTAssertEqual(context.requestedDiagnosticsURI, "file:///tmp/b.md")
    }

    // MARK: - openDiff (bare status strings, not JSON)

    func testOpenDiffAcceptedReturnsFileSaved() async throws {
        context.diffOutcome = .accepted
        let text = try textItem(await call("openDiff", [
            "old_file_path": .string("/tmp/a.md"),
            "new_file_path": .string("/tmp/a.md"),
            "new_file_contents": .string("# New\n"),
            "tab_name": .string("✻ [Claude] a.md"),
        ]))
        XCTAssertEqual(text, "FILE_SAVED")
        XCTAssertEqual(context.diffRequest?.newFileContents, "# New\n")
        XCTAssertEqual(context.diffRequest?.tabName, "✻ [Claude] a.md")
    }

    func testOpenDiffRejectedReturnsDiffRejected() async throws {
        context.diffOutcome = .rejected
        let text = try textItem(await call("openDiff", [
            "new_file_path": .string("/tmp/a.md"),
            "new_file_contents": .string("x"),
        ]))
        XCTAssertEqual(text, "DIFF_REJECTED")
    }

    func testOpenDiffSynthesizesTabNameWhenMissing() async throws {
        context.diffOutcome = .rejected
        _ = try textItem(await call("openDiff", [
            "new_file_path": .string("/tmp/sub/note.md"),
            "new_file_contents": .string("x"),
        ]))
        XCTAssertEqual(context.diffRequest?.tabName.contains("note.md"), true)
    }

    func testOpenDiffWithoutContentsIsInvalidParams() async {
        guard case .failure(let error) = await call("openDiff",
                                                    ["new_file_path": .string("/tmp/a.md")])
        else { return XCTFail("Expected failure") }
        XCTAssertEqual(error.code, RPCError.invalidParams)
    }

    func testOpenDiffWithoutAnyPathIsInvalidParams() async {
        guard case .failure(let error) = await call("openDiff",
                                                    ["new_file_contents": .string("x")])
        else { return XCTFail("Expected failure") }
        XCTAssertEqual(error.code, RPCError.invalidParams)
    }

    /// `new_file_path` wins: that is the file Claude wants written.
    func testOpenDiffTargetPathPrefersNewPath() {
        let request = OpenDiffRequest(oldFilePath: "/tmp/old.md", newFilePath: "/tmp/new.md",
                                      newFileContents: "", tabName: "t")
        XCTAssertEqual(request.targetPath, "/tmp/new.md")
        let fallback = OpenDiffRequest(oldFilePath: "/tmp/old.md", newFilePath: "",
                                       newFileContents: "", tabName: "t")
        XCTAssertEqual(fallback.targetPath, "/tmp/old.md")
    }

    // MARK: - Tabs / executeCode

    func testCloseTabAnswersTabClosed() async throws {
        let result = await call("close_tab", ["tab_name": .string("t")])
        XCTAssertEqual(try textItem(result), "TAB_CLOSED")
        XCTAssertEqual(context.closedTab, "t")
    }

    func testCloseTabWithoutNameIsInvalidParams() async {
        guard case .failure(let error) = await call("close_tab")
        else { return XCTFail("Expected failure") }
        XCTAssertEqual(error.code, RPCError.invalidParams)
    }

    func testCloseAllDiffTabsAnswersWithTheCount() async throws {
        context.openDiffTabCount = 3
        let result = await call("closeAllDiffTabs")
        XCTAssertEqual(try textItem(result), "CLOSED_3_DIFF_TABS")
    }

    func testExecuteCodeIsASoftRefusal() async throws {
        let json = try payload(await call("executeCode", ["code": .string("print(1)")]))
        XCTAssertEqual(json["success"] as? Bool, false)
        XCTAssertTrue(try XCTUnwrap(json["message"] as? String).contains("cannot execute code"))
    }

    func testUnknownToolIsMethodNotFound() async {
        guard case .failure(let error) = await call("getBacklinks")
        else { return XCTFail("Expected failure") }
        XCTAssertEqual(error.code, RPCError.methodNotFound)
    }

    // MARK: - tools/list

    /// The CLI expects exactly the standard set; a surprise entry can abort the
    /// handshake.
    func testDescriptorsAreTheTwelveStandardTools() throws {
        let names = ClaudeIDETools.descriptors.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(Set(names), [
            "getCurrentSelection", "getLatestSelection", "getOpenEditors",
            "getWorkspaceFolders", "openFile", "openDiff", "checkDocumentDirty",
            "saveDocument", "close_tab", "closeAllDiffTabs", "getDiagnostics",
            "executeCode",
        ])
        XCTAssertEqual(names.count, 12)
    }

    /// The descriptors list and the `call` switch are maintained separately;
    /// an advertised-but-unhandled tool would surface only against the live
    /// CLI as `methodNotFound`. Empty arguments may earn `invalidParams` —
    /// that still proves the switch has a case for the name.
    func testEveryAdvertisedToolIsHandled() async throws {
        for descriptor in ClaudeIDETools.descriptors {
            let name = try XCTUnwrap(descriptor["name"]?.stringValue)
            let result = await call(name)
            if case .failure(let error) = result {
                XCTAssertNotEqual(error.code, RPCError.methodNotFound,
                                  "advertised tool \(name) is not handled by call()")
            }
        }
    }

    func testDescriptorsCarryInputSchemas() throws {
        let openFile = try XCTUnwrap(ClaudeIDETools.descriptors.first {
            $0["name"]?.stringValue == "openFile"
        })
        let schema = try XCTUnwrap(openFile["inputSchema"])
        XCTAssertEqual(schema["type"]?.stringValue, "object")
        XCTAssertEqual(schema["required"]?.arrayValue?.first?.stringValue, "filePath")
        XCTAssertNotNil(schema["properties"]?["startText"])
    }
}

// MARK: - Position math

/// `selection_changed` and `getDiagnostics` both depend on this; an off-by-one
/// here silently points Claude at the wrong line.
final class IDEPositionMathTests: XCTestCase {

    private let text = "# Title\n\nSecond line\nthird\n"

    func testOffsetZeroIsOrigin() {
        XCTAssertEqual(idePosition(forUTF16Offset: 0, in: text),
                       IDEPosition(line: 0, character: 0))
    }

    func testOffsetInsideFirstLine() {
        XCTAssertEqual(idePosition(forUTF16Offset: 2, in: text),
                       IDEPosition(line: 0, character: 2))
    }

    func testOffsetAtNewlineBelongsToTheLineItTerminates() {
        // index 7 is the '\n' of line 0 → still line 0, character 7.
        XCTAssertEqual(idePosition(forUTF16Offset: 7, in: text),
                       IDEPosition(line: 0, character: 7))
        XCTAssertEqual(idePosition(forUTF16Offset: 8, in: text),
                       IDEPosition(line: 1, character: 0))
    }

    func testOffsetOnThirdLine() {
        let offset = (text as NSString).range(of: "Second").location
        XCTAssertEqual(idePosition(forUTF16Offset: offset, in: text),
                       IDEPosition(line: 2, character: 0))
    }

    func testOffsetBeyondEndClampsToEnd() {
        let end = idePosition(forUTF16Offset: 9_999, in: text)
        XCTAssertEqual(end, idePosition(forUTF16Offset: (text as NSString).length, in: text))
    }

    /// Emoji are two UTF-16 code units — the character column counts units.
    func testAstralCharactersCountAsTwoUnits() {
        let emoji = "a🎉b"
        XCTAssertEqual(idePosition(forUTF16Offset: 3, in: emoji),
                       IDEPosition(line: 0, character: 3))
    }

    func testRoundTripThroughOffset() {
        for offset in 0...(text as NSString).length {
            let position = idePosition(forUTF16Offset: offset, in: text)
            XCTAssertEqual(ideUTF16Offset(for: position, in: text), offset)
        }
    }

    func testCharacterPastEndOfLineClampsToLineEnd() {
        // Line 0 is "# Title" (7 units); character 99 must not spill onto line 1.
        XCTAssertEqual(ideUTF16Offset(for: IDEPosition(line: 0, character: 99), in: text), 7)
    }

    func testLineBeyondEndClampsToTextEnd() {
        XCTAssertEqual(ideUTF16Offset(for: IDEPosition(line: 99, character: 0), in: text),
                       (text as NSString).length)
    }

    func testSelectionRangeSpansTwoLines() {
        let range = NSRange(location: 0, length: (text as NSString).range(of: "line").location + 4)
        let selection = ideSelectionRange(for: range, in: text)
        XCTAssertEqual(selection.start, IDEPosition(line: 0, character: 0))
        XCTAssertEqual(selection.end, IDEPosition(line: 2, character: 11))
        XCTAssertFalse(selection.isEmpty)
    }

    func testZeroLengthRangeIsEmpty() {
        XCTAssertTrue(ideSelectionRange(for: NSRange(location: 3, length: 0), in: text).isEmpty)
    }

    /// `IDELineMap` (one pass + binary search, used for diagnostics lists)
    /// must agree with `idePosition` at every offset, including clamps.
    func testLineMapMatchesIdePositionEverywhere() {
        for sample in [text, "", "no newline", "\n\n", "a🎉b\nc\n"] {
            let map = IDELineMap(sample)
            let length = (sample as NSString).length
            for offset in -1...(length + 2) {
                XCTAssertEqual(map.position(forUTF16Offset: offset),
                               idePosition(forUTF16Offset: offset, in: sample),
                               "offset \(offset) in \(sample.debugDescription)")
            }
        }
    }
}

// MARK: - openFile reveal resolution

final class IDERevealRangeTests: XCTestCase {

    private let content = "# Title\n\nAlpha beta gamma\nDelta epsilon\n"

    private func request(start: String? = nil, end: String? = nil,
                         toEndOfLine: Bool = false) -> OpenFileRequest {
        OpenFileRequest(filePath: "/tmp/a.md", startText: start, endText: end,
                        selectToEndOfLine: toEndOfLine)
    }

    func testNoStartTextMeansNoReveal() {
        XCTAssertNil(ideRevealRange(for: request(), in: content))
    }

    func testStartTextOnlySelectsThatText() throws {
        let range = try XCTUnwrap(ideRevealRange(for: request(start: "beta"), in: content))
        XCTAssertEqual((content as NSString).substring(with: range), "beta")
    }

    func testStartAndEndTextSpanTheRange() throws {
        let range = try XCTUnwrap(
            ideRevealRange(for: request(start: "Alpha", end: "gamma"), in: content))
        XCTAssertEqual((content as NSString).substring(with: range), "Alpha beta gamma")
    }

    /// Claude often quotes text that has already been edited away; guessing a
    /// location would be worse than leaving the caret alone.
    func testMissingStartTextYieldsNil() {
        XCTAssertNil(ideRevealRange(for: request(start: "nowhere"), in: content))
    }

    /// A missing `endText` degrades to selecting just `startText`.
    func testMissingEndTextFallsBackToStartTextOnly() throws {
        let range = try XCTUnwrap(
            ideRevealRange(for: request(start: "Alpha", end: "nowhere"), in: content))
        XCTAssertEqual((content as NSString).substring(with: range), "Alpha")
    }

    func testSelectToEndOfLineExtendsWithoutTheNewline() throws {
        let range = try XCTUnwrap(
            ideRevealRange(for: request(start: "Alpha", toEndOfLine: true), in: content))
        XCTAssertEqual((content as NSString).substring(with: range), "Alpha beta gamma")
    }

    /// `endText` is searched forward from `startText`, never before it.
    func testEndTextIsSearchedAfterStartText() throws {
        let text = "beta ... Alpha ... beta"
        let range = try XCTUnwrap(
            ideRevealRange(for: request(start: "Alpha", end: "beta"), in: text))
        XCTAssertEqual((text as NSString).substring(with: range), "Alpha ... beta")
    }
}

// MARK: - Fake editor

private final class FakeEditorContext: IDEEditorContext, @unchecked Sendable {
    var current: IDESelection?
    var latest: IDESelection?
    var editors: [IDEEditorTab] = []
    var folders: [IDEWorkspaceFolder] = []
    var dirtyStates: [String: IDEDirtyState] = [:]
    var savableFiles: Set<String> = []
    var diagnosticFiles: [IDEDiagnosticFile] = []
    var diffOutcome: DiffOutcome = .rejected
    var openDiffTabCount = 0

    private(set) var openedFile: OpenFileRequest?
    private(set) var requestedDiagnosticsURI: String?
    private(set) var diffRequest: OpenDiffRequest?
    private(set) var closedTab: String?

    func currentSelection() async -> IDESelection? { current }
    func latestSelection() async -> IDESelection? { latest }
    func openEditors() async -> [IDEEditorTab] { editors }
    func workspaceFolders() async -> [IDEWorkspaceFolder] { folders }

    func openFile(_ request: OpenFileRequest) async -> OpenFileOutcome {
        openedFile = request
        return OpenFileOutcome(success: true, message: "opened")
    }

    func documentDirtyState(path: String) async -> IDEDirtyState? { dirtyStates[path] }
    func saveDocument(path: String) async -> Bool { savableFiles.contains(path) }

    func diagnostics(uri: String?) async -> [IDEDiagnosticFile] {
        requestedDiagnosticsURI = uri
        return diagnosticFiles
    }

    func openDiff(_ request: OpenDiffRequest) async -> DiffOutcome {
        diffRequest = request
        return diffOutcome
    }

    func closeDiffTab(named tabName: String) async -> Bool {
        closedTab = tabName
        return true
    }

    func closeAllDiffTabs() async -> Int { openDiffTabCount }
}
