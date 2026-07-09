import SwiftUI
import AppKit

// MARK: - Snapshot for status bar / menus

/// Lightweight git affordances for the focused file (stage 4 / 5).
struct GitFileSnapshot: Equatable {
    var inRepo: Bool
    var pathStatus: GitCLI.PathStatus
    var branch: String?
    /// Commits ahead of upstream; nil if no upstream.
    var ahead: Int?
    var behind: Int?
    /// Session dirty-line count (gutter marks), not git porcelain.
    var sessionDirtyLines: Int
    /// Document buffer dirty (unsaved).
    var bufferDirty: Bool
    /// Line-level `+` / `−` vs HEAD (open buffer if any, else worktree).
    var added: Int
    var removed: Int

    static let empty = GitFileSnapshot(
        inRepo: false, pathStatus: .notInRepo, branch: nil,
        ahead: nil, behind: nil, sessionDirtyLines: 0, bufferDirty: false,
        added: 0, removed: 0
    )

    /// True when there is something to show as green/red counts.
    var hasLineDelta: Bool { added > 0 || removed > 0 }

    var canCommit: Bool {
        guard inRepo else { return false }
        switch pathStatus {
        case .modified, .untracked, .deleted: return true
        case .clean:
            // Unsaved buffer still worth committing after save.
            return bufferDirty || sessionDirtyLines > 0
        case .notInRepo: return false
        }
    }

    var canPush: Bool {
        guard inRepo else { return false }
        // Allow push when ahead, or when upstream exists with 0 ahead
        // (user may still want to push after a just-made commit before refresh).
        // Disable only when we know ahead == 0.
        if let ahead { return ahead > 0 }
        // No upstream info — still offer Push (git will error with a clear message).
        return true
    }

    var statusCaption: String {
        guard inRepo else { return "" }
        switch pathStatus {
        case .modified: return "modified"
        case .untracked: return "untracked"
        case .deleted: return "deleted"
        case .clean:
            if bufferDirty { return "unsaved" }
            if sessionDirtyLines > 0 { return "edited" }
            return "clean"
        case .notInRepo: return ""
        }
    }
}

@MainActor
enum GitFileStatus {
    /// Blocking snapshot — call off the critical UI path or after edits settle.
    static func snapshot(for url: URL?) -> GitFileSnapshot {
        guard let url else { return .empty }
        let key = url.standardizedFileURL
        guard GitCLI.gitExecutable != nil else { return .empty }
        let sessionDirty = LineChangeTracker.shared.dirtyLines(for: key).count
        let bufferDirty = DocumentRegistry.shared.isDirty(key)
        guard GitCLI.repositoryRoot(containing: key) != nil else {
            return GitFileSnapshot(
                inRepo: false, pathStatus: .notInRepo, branch: nil,
                ahead: nil, behind: nil,
                sessionDirtyLines: sessionDirty,
                bufferDirty: bufferDirty,
                added: 0, removed: 0
            )
        }
        let status = GitCLI.pathStatus(of: key)
        let branch = GitCLI.currentBranch(containing: key)
        let ab = GitCLI.aheadBehind(containing: key)
        // Skip full HEAD/buffer diff when porcelain is clean and the buffer
        // matches HEAD (no session marks / unsaved) — avoids `git show` on
        // every idle refresh of an untouched file.
        let delta: (Int, Int)
        if status == .clean && !bufferDirty && sessionDirty == 0 {
            delta = (0, 0)
        } else {
            delta = lineDelta(for: key)
        }
        return GitFileSnapshot(
            inRepo: true,
            pathStatus: status,
            branch: branch,
            ahead: ab?.ahead,
            behind: ab?.behind,
            sessionDirtyLines: sessionDirty,
            bufferDirty: bufferDirty,
            added: delta.0,
            removed: delta.1
        )
    }

    /// `+` / `−` line counts: HEAD vs open buffer (preferred) or worktree.
    /// Same sides as the git-sidebar Diff sheet.
    static func lineDelta(for file: URL) -> (added: Int, removed: Int) {
        let before = GitCLI.headFileContents(of: file)
        let after: String
        if let open = DocumentRegistry.shared.contentIfOpen(file) {
            after = open
        } else {
            after = GitCLI.workingTreeContents(of: file) ?? ""
        }
        if before == after { return (0, 0) }
        let r = lineDiff(before: before, after: after)
        return (r.added, r.removed)
    }
}

// MARK: - Suggested commit message (short English, contextual)

/// Builds a one-line default for the Commit sheet. Pure / testable.
/// Examples: `Add note.md`, `Update note.md (L12–18)`, `Update a.md (L3, L9)`.
enum GitCommitMessage {
    /// Max separate ranges in the parenthetical (extra → `…`).
    static let maxRanges = 4

    static func suggested(
        fileName: String,
        pathStatus: GitCLI.PathStatus,
        dirtyLines: Set<Int> = []
    ) -> String {
        let name = fileName.isEmpty ? "file" : fileName
        switch pathStatus {
        case .untracked:
            return "Add \(name)"
        case .deleted:
            return "Delete \(name)"
        case .modified, .clean, .notInRepo:
            if let span = formatLineSpan(dirtyLines), !span.isEmpty {
                return "Update \(name) (\(span))"
            }
            return "Update \(name)"
        }
    }

    /// Collapses 1-based line numbers into `L3`, `L12–18`, `L3, L9, L20–22`.
    static func formatLineSpan(_ lines: Set<Int>) -> String? {
        let sorted = lines.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }

        var ranges: [(Int, Int)] = []
        var start = sorted[0]
        var end = sorted[0]
        for n in sorted.dropFirst() {
            if n == end + 1 {
                end = n
            } else {
                ranges.append((start, end))
                start = n
                end = n
            }
        }
        ranges.append((start, end))

        let shown = ranges.prefix(maxRanges)
        var parts: [String] = shown.map { s, e in
            s == e ? "L\(s)" : "L\(s)–\(e)"
        }
        if ranges.count > maxRanges {
            parts.append("…")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Commit sheet (stage 4)

struct GitCommitSheet: View {
    let fileURL: URL
    /// Optional live content for dirty-line count in the header.
    var documentContent: String = ""
    let onClose: () -> Void
    /// Called after a successful commit (marks already re-anchored).
    var onCommitted: (() -> Void)? = nil

    @State private var message: String = ""
    @State private var isBusy = false
    @State private var errorText: String?
    @State private var successHash: String?
    @State private var pushNote: String?
    @State private var pushError: String?
    @FocusState private var messageFocused: Bool

    private var fileName: String { fileURL.lastPathComponent }
    private var branch: String? { GitCLI.currentBranch(containing: fileURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(successHash == nil ? "Commit file" : "Committed")
                    .font(.headline)
                Spacer()
                if let branch {
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

            Text(fileName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            if let successHash {
                successBody(hash: successHash)
            } else {
                commitBody
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 480)
        .onAppear {
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = suggestedMessage()
            }
            messageFocused = true
        }
    }

    private func suggestedMessage() -> String {
        let status = GitCLI.pathStatus(of: fileURL)
        // Prefer session gutter marks (what the user just edited); fall back to
        // git diff line numbers when marks are empty but the file is modified.
        var dirty = LineChangeTracker.shared.dirtyLines(for: fileURL)
        if dirty.isEmpty, status == .modified || status == .clean {
            dirty = GitCLI.changedLineNumbers(of: fileURL)
        }
        return GitCommitMessage.suggested(
            fileName: fileName,
            pathStatus: status,
            dirtyLines: dirty
        )
    }

    private var commitBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Only this file will be staged and committed (`git add` + `git commit -- path`).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $message)
                .font(.system(size: 13))
                .frame(minHeight: 88, maxHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .focused($messageFocused)
                .disabled(isBusy)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button(isBusy ? "Committing…" : "Commit") {
                    performCommit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func successBody(hash: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Created commit \(String(hash.prefix(7)))")
                    .font(.system(size: 12, design: .monospaced))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            if let pushError {
                Text(pushError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if let pushNote {
                Text(pushNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Dirty line marks were cleared. Push when you are ready.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                Button(isBusy ? "Pushing…" : "Push…") {
                    performPush()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
            }
        }
    }

    private func performCommit() {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else {
            errorText = "Commit message is empty."
            return
        }
        isBusy = true
        errorText = nil
        // 1) Flush buffer so git sees current text.
        do {
            try DocumentRegistry.shared.saveNow(fileURL)
        } catch {
            isBusy = false
            errorText = "Save failed: \(error.localizedDescription)"
            return
        }
        // 2) Stage + commit on a utility queue (Process is blocking).
        let url = fileURL
        Task.detached(priority: .userInitiated) {
            let result = GitCLI.commit(file: url, message: msg)
            await MainActor.run {
                isBusy = false
                switch result {
                case .success(let hash):
                    // Re-anchor session marks to the committed buffer.
                    let content = DocumentRegistry.shared.contentIfOpen(url)
                        ?? (try? loadMarkdownDocument(from: url).content)
                        ?? ""
                    LineChangeTracker.shared.noteBaseline(url: url, content: content)
                    GitCommitWatcher.shared.noteCommitted(url: url, hash: hash)
                    NotificationCenter.default.post(name: .gitRepositoryDidChange, object: url)
                    successHash = hash
                    onCommitted?()
                case .failure(let err):
                    errorText = err.message
                }
            }
        }
    }

    private func performPush() {
        isBusy = true
        pushError = nil
        pushNote = nil
        let url = fileURL
        // Confirm first (stage 5).
        let alert = NSAlert()
        alert.messageText = "Push to remote?"
        let branchName = branch ?? "current branch"
        alert.informativeText = "This runs `git push` for “\(branchName)” using your system credentials (Keychain / SSH agent). Network access required."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Push")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            isBusy = false
            return
        }
        Task.detached(priority: .userInitiated) {
            let result = GitCLI.push(containing: url)
            await MainActor.run {
                isBusy = false
                switch result {
                case .success(let note):
                    pushNote = note
                    NotificationCenter.default.post(name: .gitRepositoryDidChange, object: url)
                case .failure(let err):
                    pushError = err.message
                }
            }
        }
    }
}

// MARK: - Standalone push confirm (File menu / status bar)

@MainActor
enum GitPushConfirm {
    /// Shows an NSAlert then runs `git push`. Returns a user-visible outcome string.
    @discardableResult
    static func run(for fileURL: URL) -> String? {
        guard GitCLI.repositoryRoot(containing: fileURL) != nil else {
            presentError("Not inside a git repository.")
            return nil
        }
        let branch = GitCLI.currentBranch(containing: fileURL) ?? "current branch"
        let ab = GitCLI.aheadBehind(containing: fileURL)
        let alert = NSAlert()
        alert.messageText = "Push to remote?"
        var info = "Branch: \(branch)\nRuns `git push` with system credentials (Keychain / SSH)."
        if let ab {
            if ab.ahead == 0 {
                info += "\n\nNothing to push (0 commits ahead of upstream)."
            } else {
                info += "\n\n\(ab.ahead) commit(s) ahead"
                if ab.behind > 0 { info += ", \(ab.behind) behind" }
                info += "."
            }
        } else {
            info += "\n\nNo upstream configured — git will report the error if push cannot proceed."
        }
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Push")
        alert.addButton(withTitle: "Cancel")
        if ab?.ahead == 0 {
            // Still allow (force user intent) but default Cancel is fine.
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        // Process is blocking; typical push is short. Credential prompts are
        // handled by the system helper / ssh-agent outside this process.
        let result = GitCLI.push(containing: fileURL)
        NotificationCenter.default.post(name: .gitRepositoryDidChange, object: fileURL)
        switch result {
        case .success(let note):
            let done = NSAlert()
            done.messageText = "Push completed"
            done.informativeText = note
            done.alertStyle = .informational
            done.addButton(withTitle: "OK")
            done.runModal()
            return note
        case .failure(let err):
            presentError(err.message)
            return nil
        }
    }

    private static func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Push failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Workspace git snapshot (sidebar)

/// One changed markdown file under a workspace root.
struct GitChangedFile: Equatable, Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    /// Display path relative to the owning workspace folder when possible.
    let displayPath: String
    let pathStatus: GitCLI.PathStatus
    let sessionDirtyLines: Int
    let bufferDirty: Bool

    var statusBadge: String {
        switch pathStatus {
        case .untracked: return "?"
        case .deleted: return "D"
        case .modified, .clean, .notInRepo: return "M"
        }
    }

    var canCommit: Bool {
        switch pathStatus {
        case .modified, .untracked, .deleted: return true
        case .clean: return bufferDirty || sessionDirtyLines > 0
        case .notInRepo: return false
        }
    }
}

/// Changed files grouped by git repository root.
struct GitRepoSection: Equatable, Identifiable, Sendable {
    var id: String { root.path }
    let root: URL
    let branch: String?
    let ahead: Int?
    let behind: Int?
    let files: [GitChangedFile]

    var shortRoot: String {
        (root.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Workspace-scoped git overview for the Git sidebar tab.
struct GitWorkspaceSnapshot: Equatable, Sendable {
    /// Distinct repos that own at least one workspace folder.
    let sections: [GitRepoSection]
    /// Open editor buffers that are dirty but not already listed in `sections`.
    let openDirty: [GitChangedFile]
    /// At least one workspace folder sits inside a git work tree.
    let hasAnyRepo: Bool
    /// Workspace list was empty when built.
    let hasWorkspaces: Bool

    static let empty = GitWorkspaceSnapshot(
        sections: [], openDirty: [], hasAnyRepo: false, hasWorkspaces: false
    )

    var changedCount: Int { sections.reduce(0) { $0 + $1.files.count } }
    var isClean: Bool { hasAnyRepo && changedCount == 0 && openDirty.isEmpty }
}

@MainActor
enum GitWorkspaceStatus {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "textbundle"]

    /// Build a snapshot from adopted workspace roots + currently open docs.
    /// Uses one `git status` per repository (not per file).
    static func snapshot(
        workspaceRoots: [URL],
        openURLs: [URL] = DocumentRegistry.shared.openURLs
    ) -> GitWorkspaceSnapshot {
        guard GitCLI.gitExecutable != nil else {
            return GitWorkspaceSnapshot(
                sections: [], openDirty: [], hasAnyRepo: false,
                hasWorkspaces: !workspaceRoots.isEmpty
            )
        }
        let roots = workspaceRoots.map { $0.standardizedFileURL }
        guard !roots.isEmpty else { return .empty }

        // Group workspace folders by their git root.
        var workspacesByRepo: [URL: [URL]] = [:]
        var hasAnyRepo = false
        for ws in roots {
            guard let repo = GitCLI.repositoryRoot(containing: ws) else { continue }
            hasAnyRepo = true
            workspacesByRepo[repo, default: []].append(ws)
        }

        var sections: [GitRepoSection] = []
        var changedURLs = Set<URL>()

        for (repo, workspaces) in workspacesByRepo.sorted(by: { $0.key.path < $1.key.path }) {
            let branch = GitCLI.currentBranch(containing: repo)
            let ab = GitCLI.aheadBehind(containing: repo)
            let entries = GitCLI.porcelainStatus(in: repo)
            var files: [GitChangedFile] = []

            for entry in entries {
                let fileURL = repo.appendingPathComponent(entry.relativePath).standardizedFileURL
                guard isMarkdown(fileURL) else { continue }
                guard let ws = owningWorkspace(fileURL, among: workspaces) else { continue }
                let display = displayPath(of: fileURL, workspace: ws, repo: repo)
                let key = fileURL
                let item = GitChangedFile(
                    url: key,
                    displayPath: display,
                    pathStatus: entry.status,
                    sessionDirtyLines: LineChangeTracker.shared.dirtyLines(for: key).count,
                    bufferDirty: DocumentRegistry.shared.isDirty(key)
                )
                files.append(item)
                changedURLs.insert(key)
            }

            files.sort {
                $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending
            }

            sections.append(GitRepoSection(
                root: repo,
                branch: branch,
                ahead: ab?.ahead,
                behind: ab?.behind,
                files: files
            ))
        }

        // Open buffers: unsaved / session marks, in workspace, not already listed.
        var openDirty: [GitChangedFile] = []
        for open in openURLs {
            let key = open.standardizedFileURL
            guard !changedURLs.contains(key) else { continue }
            guard isMarkdown(key) else { continue }
            guard let ws = owningWorkspace(key, among: roots) else { continue }
            let bufferDirty = DocumentRegistry.shared.isDirty(key)
            let sessionLines = LineChangeTracker.shared.dirtyLines(for: key).count
            guard bufferDirty || sessionLines > 0 else { continue }
            // Must be inside a git repo to be interesting here.
            guard let repo = GitCLI.repositoryRoot(containing: key) else { continue }
            let status = GitCLI.pathStatus(of: key)
            openDirty.append(GitChangedFile(
                url: key,
                displayPath: displayPath(of: key, workspace: ws, repo: repo),
                pathStatus: status == .notInRepo ? .clean : status,
                sessionDirtyLines: sessionLines,
                bufferDirty: bufferDirty
            ))
        }
        openDirty.sort {
            $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending
        }

        return GitWorkspaceSnapshot(
            sections: sections,
            openDirty: openDirty,
            hasAnyRepo: hasAnyRepo,
            hasWorkspaces: true
        )
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Longest workspace prefix that contains `url`.
    private static func owningWorkspace(_ url: URL, among workspaces: [URL]) -> URL? {
        let path = url.standardizedFileURL.path
        return workspaces
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max(by: { $0.path.count < $1.path.count })
    }

    private static func displayPath(of file: URL, workspace: URL, repo: URL) -> String {
        let relWS = GitCLI.relativePath(of: file, to: workspace)
        if !relWS.isEmpty { return relWS }
        return GitCLI.relativePath(of: file, to: repo)
    }

    /// Before/after for the unified diff sheet (git sidebar).
    /// HEAD blob vs open buffer (if any) else working tree; deleted → empty after.
    static func diffSheetContent(for file: URL) -> DiffSheetContent {
        let before = GitCLI.headFileContents(of: file)
        let after: String
        let sideLabel: String
        if let open = DocumentRegistry.shared.contentIfOpen(file) {
            after = open
            sideLabel = DocumentRegistry.shared.isDirty(file)
                ? "HEAD → buffer (unsaved)"
                : "HEAD → buffer"
        } else {
            after = GitCLI.workingTreeContents(of: file) ?? ""
            switch GitCLI.pathStatus(of: file) {
            case .untracked: sideLabel = "new file"
            case .deleted: sideLabel = "HEAD → deleted"
            default: sideLabel = "HEAD → working tree"
            }
        }
        return DiffSheetContent(
            title: "Git diff",
            fileName: file.lastPathComponent,
            sideLabel: sideLabel,
            before: before,
            after: after
        )
    }
}

// MARK: - Status-bar label (info only; actions live in the Git sidebar)

struct GitStatusChip: View {
    let snapshot: GitFileSnapshot
    /// Optional: open the Git sidebar tab (status bar is display-only).
    var onTap: (() -> Void)? = nil

    var body: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if let branch = snapshot.branch {
                Text(branch)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Prefer concrete +N/−M over the word "modified" when we have them.
            if snapshot.hasLineDelta {
                DiffStatsLabel(
                    added: snapshot.added,
                    removed: snapshot.removed,
                    font: .system(size: 11, design: .monospaced)
                )
            } else if !snapshot.statusCaption.isEmpty, snapshot.statusCaption != "clean" {
                Text(snapshot.statusCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(snapshot.pathStatus == .clean ? Color.secondary : Color.orange)
            }

            // Unsaved with no line delta yet (e.g. whitespace-only) still tip.
            if snapshot.bufferDirty, !snapshot.hasLineDelta {
                Text("unsaved")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if let ahead = snapshot.ahead, ahead > 0 {
                Text("↑\(ahead)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .help("\(ahead) commit(s) to push")
            }

            if let behind = snapshot.behind, behind > 0 {
                Text("↓\(behind)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("\(behind) commit(s) to pull")
            }
        }
        if let onTap {
            Button(action: onTap) { label }
                .buttonStyle(.plain)
                .help(statusBarHelp)
        } else {
            label
        }
    }

    private var statusBarHelp: String {
        var parts: [String] = ["Show Git sidebar"]
        if snapshot.hasLineDelta {
            parts.append("lines vs HEAD: +\(snapshot.added) −\(snapshot.removed)")
        }
        return parts.joined(separator: " · ")
    }
}
