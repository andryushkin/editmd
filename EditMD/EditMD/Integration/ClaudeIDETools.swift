import Foundation

// The 12 standard IDE tools Claude Code calls over the WebSocket channel (v36).
//
// Names, parameters and response shapes follow the spec verbatim
// (`docs/research/claude-code-integration.md`, 2.4) — including the two quirks:
//   * `close_tab` is snake_case while everything else is camelCase;
//   * the useful payload is a JSON **string** inside `content[0].text`.
//
// Everything here is transport- and UI-free: the tools talk to an
// `IDEEditorContext`, which the app satisfies with a main-actor facade
// (`ClaudeIDEBridge`) and the tests satisfy with a fake.

// MARK: - Value types

/// Zero-based line + UTF-16 character offset within that line (LSP / VS Code
/// convention). Coordinates are always in **markdown source** space, even when
/// the user is looking at the Visual (WYSIWYG) rendering.
struct IDEPosition: Equatable, Sendable {
    var line: Int
    var character: Int
}

struct IDESelectionRange: Equatable, Sendable {
    var start: IDEPosition
    var end: IDEPosition
    var isEmpty: Bool { start == end }
}

struct IDESelection: Equatable, Sendable {
    var text: String
    var filePath: String
    var range: IDESelectionRange

    var fileURL: String { URL(fileURLWithPath: filePath).absoluteString }
}

// Wire encoding lives on the value types: `getCurrentSelection` replies and
// `selection_changed` notifications carry the same shape and must not drift.

extension IDEPosition {
    var jsonValue: JSONValue {
        .object(["line": .int(line), "character": .int(character)])
    }
}

extension IDESelectionRange {
    var jsonValue: JSONValue {
        .object(["start": start.jsonValue,
                 "end": end.jsonValue,
                 "isEmpty": .bool(isEmpty)])
    }
}

extension IDESelection {
    var payloadFields: [String: JSONValue] {
        ["text": .string(text),
         "filePath": .string(filePath),
         "fileUrl": .string(fileURL),
         "selection": range.jsonValue]
    }
}

struct IDEEditorTab: Equatable, Sendable {
    var path: String
    var isActive: Bool
    var isDirty: Bool

    var uri: String { URL(fileURLWithPath: path).absoluteString }
    var label: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct IDEWorkspaceFolder: Equatable, Sendable {
    var path: String

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var uri: String { URL(fileURLWithPath: path, isDirectory: true).absoluteString }
}

struct IDEDirtyState: Equatable, Sendable {
    var isDirty: Bool
    var isUntitled: Bool
}

struct OpenFileRequest: Equatable, Sendable {
    var filePath: String
    var startText: String?
    var endText: String?
    var selectToEndOfLine: Bool = false
    var makeFrontmost: Bool = true
}

struct OpenFileOutcome: Equatable, Sendable {
    var success: Bool
    var message: String
}

struct OpenDiffRequest: Equatable, Sendable {
    var oldFilePath: String?
    var newFilePath: String?
    var newFileContents: String
    var tabName: String

    /// The file the diff is really about. `new_file_path` wins (Claude sets it
    /// to the file it wants written); `old_file_path` is the fallback for the
    /// "compare against this" form.
    var targetPath: String? {
        if let newFilePath, !newFilePath.isEmpty { return newFilePath }
        if let oldFilePath, !oldFilePath.isEmpty { return oldFilePath }
        return nil
    }
}

/// The only blocking tool: `openDiff` suspends until the user answers.
enum DiffOutcome: String, Equatable, Sendable {
    /// User accepted — the IDE wrote `new_file_contents` itself.
    case accepted = "FILE_SAVED"
    /// User rejected, closed the sheet, the client disconnected, or we timed out.
    case rejected = "DIFF_REJECTED"
}

/// One lint finding mapped onto the LSP-ish shape Claude expects.
struct IDEDiagnostic: Equatable, Sendable {
    var message: String
    /// `"Error"` / `"Warning"` — a name, not a number (see v36 gotchas).
    var severity: String
    var source: String
    var code: String
    var range: IDESelectionRange
}

struct IDEDiagnosticFile: Equatable, Sendable {
    var uri: String
    var diagnostics: [IDEDiagnostic]
}

// MARK: - Editor context

/// Everything the tools need from the running editor. Async because the real
/// implementation hops to the main actor (and `openDiff` waits for a human).
protocol IDEEditorContext: Sendable {
    func currentSelection() async -> IDESelection?
    func latestSelection() async -> IDESelection?
    func openEditors() async -> [IDEEditorTab]
    func workspaceFolders() async -> [IDEWorkspaceFolder]
    func openFile(_ request: OpenFileRequest) async -> OpenFileOutcome
    func documentDirtyState(path: String) async -> IDEDirtyState?
    func saveDocument(path: String) async -> Bool
    func diagnostics(uri: String?) async -> [IDEDiagnosticFile]
    func openDiff(_ request: OpenDiffRequest) async -> DiffOutcome
    func closeDiffTab(named tabName: String) async -> Bool
    func closeAllDiffTabs() async -> Int
}

// MARK: - Position math (markdown offsets ⇄ line/character)

/// UTF-16 offset → zero-based `(line, character)` in `text`.
func idePosition(forUTF16Offset offset: Int, in text: String) -> IDEPosition {
    let nsText = text as NSString
    let clamped = max(0, min(offset, nsText.length))
    var line = 0
    var lineStart = 0
    var index = 0
    while index < clamped {
        if nsText.character(at: index) == 0x0A {
            line += 1
            lineStart = index + 1
        }
        index += 1
    }
    return IDEPosition(line: line, character: clamped - lineStart)
}

/// Inverse of `idePosition(forUTF16Offset:in:)`; clamps out-of-range input.
func ideUTF16Offset(for position: IDEPosition, in text: String) -> Int {
    let nsText = text as NSString
    var line = 0
    var index = 0
    while index < nsText.length, line < position.line {
        if nsText.character(at: index) == 0x0A { line += 1 }
        index += 1
    }
    guard line == position.line else { return nsText.length }
    // Don't let `character` walk past the end of its own line.
    var end = index
    while end < nsText.length, nsText.character(at: end) != 0x0A { end += 1 }
    return min(index + max(0, position.character), end)
}

/// UTF-16 range → selection range in `text`.
func ideSelectionRange(for range: NSRange, in text: String) -> IDESelectionRange {
    IDESelectionRange(start: idePosition(forUTF16Offset: range.location, in: text),
                      end: idePosition(forUTF16Offset: NSMaxRange(range), in: text))
}

/// Line starts (UTF-16) built in one pass — for mapping many offsets against
/// the same text. `idePosition` rescans the prefix per call, which is fine for
/// a single selection but quadratic for a diagnostics list.
struct IDELineMap: Sendable {
    private let lineStarts: [Int]
    private let length: Int

    init(_ text: String) {
        let nsText = text as NSString
        var starts = [0]
        var index = 0
        while index < nsText.length {
            if nsText.character(at: index) == 0x0A { starts.append(index + 1) }
            index += 1
        }
        lineStarts = starts
        length = nsText.length
    }

    func position(forUTF16Offset offset: Int) -> IDEPosition {
        let clamped = max(0, min(offset, length))
        // Last line start ≤ clamped, by binary search.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= clamped { low = mid } else { high = mid - 1 }
        }
        return IDEPosition(line: low, character: clamped - lineStarts[low])
    }

    func selectionRange(for range: NSRange) -> IDESelectionRange {
        IDESelectionRange(start: position(forUTF16Offset: range.location),
                          end: position(forUTF16Offset: NSMaxRange(range)))
    }
}

// MARK: - Tools

struct ClaudeIDETools: Sendable {

    let context: any IDEEditorContext

    // MARK: Dispatch

    func call(name: String, arguments: JSONValue) async -> Result<JSONValue, RPCError> {
        switch name {
        case "getCurrentSelection":
            return .success(selectionPayload(await context.currentSelection()))

        case "getLatestSelection":
            return .success(selectionPayload(await context.latestSelection()))

        case "getOpenEditors":
            let tabs = await context.openEditors().map { tab in
                JSONValue.object([
                    "uri": .string(tab.uri),
                    "isActive": .bool(tab.isActive),
                    "label": .string(tab.label),
                    "languageId": .string("markdown"),
                    "isDirty": .bool(tab.isDirty),
                ])
            }
            return .success(MCPContent.json(.object(["tabs": .array(tabs)])))

        case "getWorkspaceFolders":
            let folders = await context.workspaceFolders()
            return .success(status(true, extra: [
                "folders": .array(folders.map { folder in
                    .object([
                        "name": .string(folder.name),
                        "uri": .string(folder.uri),
                        "path": .string(folder.path),
                    ])
                }),
                "rootPath": folders.first.map { .string($0.path) } ?? .null,
            ]))

        case "openFile":
            guard let filePath = arguments["filePath"]?.stringValue, !filePath.isEmpty else {
                return .failure(.invalidParams("openFile requires filePath"))
            }
            let request = OpenFileRequest(
                filePath: filePath,
                startText: arguments["startText"]?.stringValue,
                endText: arguments["endText"]?.stringValue,
                selectToEndOfLine: arguments["selectToEndOfLine"]?.boolValue ?? false,
                makeFrontmost: arguments["makeFrontmost"]?.boolValue ?? true
            )
            let outcome = await context.openFile(request)
            return .success(status(outcome.success, filePath: filePath,
                                   message: outcome.message))

        case "checkDocumentDirty":
            guard let filePath = arguments["filePath"]?.stringValue, !filePath.isEmpty else {
                return .failure(.invalidParams("checkDocumentDirty requires filePath"))
            }
            guard let state = await context.documentDirtyState(path: filePath) else {
                return .success(status(false, filePath: filePath,
                                       message: "Document not open in EditMD: \(filePath)"))
            }
            return .success(status(true, filePath: filePath, extra: [
                "isDirty": .bool(state.isDirty),
                "isUntitled": .bool(state.isUntitled),
            ]))

        case "saveDocument":
            guard let filePath = arguments["filePath"]?.stringValue, !filePath.isEmpty else {
                return .failure(.invalidParams("saveDocument requires filePath"))
            }
            let saved = await context.saveDocument(path: filePath)
            return .success(status(saved, filePath: filePath,
                                   message: saved
                                       ? "Saved \(filePath)"
                                       : "Document not open in EditMD: \(filePath)"))

        case "getDiagnostics":
            let uri = arguments["uri"]?.stringValue
            let files = await context.diagnostics(uri: uri)
            return .success(MCPContent.json(.array(files.map(diagnosticFilePayload))))

        case "openDiff":
            guard let newFileContents = arguments["new_file_contents"]?.stringValue else {
                return .failure(.invalidParams("openDiff requires new_file_contents"))
            }
            let oldPath = arguments["old_file_path"]?.stringValue
            let newPath = arguments["new_file_path"]?.stringValue
            let request = OpenDiffRequest(
                oldFilePath: oldPath,
                newFilePath: newPath,
                newFileContents: newFileContents,
                tabName: arguments["tab_name"]?.stringValue
                    ?? defaultTabName(oldPath: oldPath, newPath: newPath)
            )
            guard request.targetPath != nil else {
                return .failure(.invalidParams("openDiff requires old_file_path or new_file_path"))
            }
            let outcome = await context.openDiff(request)
            // Bare status string, not a JSON payload — the CLI matches on it.
            return .success(MCPContent.text(outcome.rawValue))

        case "close_tab":
            guard let tabName = arguments["tab_name"]?.stringValue, !tabName.isEmpty else {
                return .failure(.invalidParams("close_tab requires tab_name"))
            }
            _ = await context.closeDiffTab(named: tabName)
            return .success(MCPContent.text("TAB_CLOSED"))

        case "closeAllDiffTabs":
            let count = await context.closeAllDiffTabs()
            return .success(MCPContent.text("CLOSED_\(count)_DIFF_TABS"))

        case "executeCode":
            return .success(status(false, message:
                "EditMD is a markdown editor and cannot execute code. "
                + "Run the code in your terminal instead."))

        default:
            return .failure(RPCError(code: RPCError.methodNotFound,
                                     message: "Unknown tool: \(name)"))
        }
    }

    // MARK: Payload helpers

    /// The `{success, filePath?, message?, …}` envelope every non-blocking
    /// tool answers with. One builder — the CLI parses these keys.
    private func status(_ success: Bool,
                        filePath: String? = nil,
                        message: String? = nil,
                        extra: [String: JSONValue] = [:]) -> JSONValue {
        var payload: [String: JSONValue] = ["success": .bool(success)]
        if let filePath { payload["filePath"] = .string(filePath) }
        if let message { payload["message"] = .string(message) }
        payload.merge(extra) { _, new in new }
        return MCPContent.json(.object(payload))
    }

    private func selectionPayload(_ selection: IDESelection?) -> JSONValue {
        guard let selection else {
            return status(false, message: "No active editor in EditMD")
        }
        var payload = selection.payloadFields
        payload["success"] = .bool(true)
        return MCPContent.json(.object(payload))
    }

    private func diagnosticFilePayload(_ file: IDEDiagnosticFile) -> JSONValue {
        .object([
            "uri": .string(file.uri),
            "diagnostics": .array(file.diagnostics.map { diagnostic in
                .object([
                    "message": .string(diagnostic.message),
                    "severity": .string(diagnostic.severity),
                    "source": .string(diagnostic.source),
                    "code": .string(diagnostic.code),
                    "range": diagnostic.range.jsonValue,
                ])
            }),
        ])
    }

    private func defaultTabName(oldPath: String?, newPath: String?) -> String {
        let path = newPath ?? oldPath ?? "untitled"
        return "✻ [Claude] \(URL(fileURLWithPath: path).lastPathComponent)"
    }
}

// MARK: - tools/list descriptors

extension ClaudeIDETools {

    /// The fixed set the CLI expects. Extra (EditMD-specific) tools are
    /// deliberately absent — the CLI filters `tools/list` against its own table
    /// and a surprise entry can abort the handshake (spec, phase 1.5).
    static var descriptors: [JSONValue] {
        [
            tool("getCurrentSelection",
                 "Current selection in the active EditMD editor (markdown source coordinates)."),
            tool("getLatestSelection",
                 "Most recent non-empty selection, even if focus moved away."),
            tool("getOpenEditors",
                 "Files currently open in EditMD, with their dirty state."),
            tool("getWorkspaceFolders",
                 "Workspace folders adopted in the EditMD sidebar."),
            tool("openFile",
                 "Open a file in EditMD and optionally select a text range.",
                 properties: [
                    "filePath": schema("string", "Absolute path of the file to open."),
                    "preview": schema("boolean", "Open in preview (transient) mode."),
                    "startText": schema("string", "Text to search for; selection starts here."),
                    "endText": schema("string", "Text to search for; selection ends here."),
                    "selectToEndOfLine": schema("boolean", "Extend the selection to end of line."),
                    "makeFrontmost": schema("boolean", "Bring the EditMD window forward."),
                 ],
                 required: ["filePath"]),
            tool("openDiff",
                 "Show a diff in EditMD and wait for the user to accept or reject it. "
                 + "Returns FILE_SAVED when accepted (EditMD writes the file), "
                 + "DIFF_REJECTED otherwise.",
                 properties: [
                    "old_file_path": schema("string", "Absolute path of the original file."),
                    "new_file_path": schema("string", "Absolute path of the file to write."),
                    "new_file_contents": schema("string", "Proposed full contents."),
                    "tab_name": schema("string", "Title for the diff tab."),
                 ],
                 required: ["new_file_contents"]),
            tool("checkDocumentDirty",
                 "Whether an open document has unsaved changes.",
                 properties: ["filePath": schema("string", "Absolute path.")],
                 required: ["filePath"]),
            tool("saveDocument",
                 "Save an open document to disk.",
                 properties: ["filePath": schema("string", "Absolute path.")],
                 required: ["filePath"]),
            tool("close_tab",
                 "Close a Claude diff tab by name.",
                 properties: ["tab_name": schema("string", "Tab title.")],
                 required: ["tab_name"]),
            tool("closeAllDiffTabs",
                 "Close every open Claude diff tab."),
            tool("getDiagnostics",
                 "Markdown lint diagnostics from EditMD (14 rules).",
                 properties: ["uri": schema("string", "file:// URI; omit for the active file.")]),
            tool("executeCode",
                 "Not supported by EditMD (Jupyter-only tool)."),
        ]
    }

    private static func tool(_ name: String,
                             _ description: String,
                             properties: [String: JSONValue] = [:],
                             required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object(schema),
        ])
    }

    private static func schema(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }
}
