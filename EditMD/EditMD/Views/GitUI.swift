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
        case .modified: return String(localized: "modified")
        case .untracked: return String(localized: "untracked")
        case .deleted: return String(localized: "deleted")
        case .clean:
            if bufferDirty { return String(localized: "unsaved") }
            if sessionDirtyLines > 0 { return String(localized: "edited") }
            return String(localized: "clean")
        case .notInRepo: return ""
        }
    }
}

/// How much work a status-bar refresh should do.
enum GitSnapshotRefresh: Sendable {
    /// `rev-parse` / status / branch / ahead-behind + line delta (file open, focus, commit).
    case full
    /// Reuse previous meta; only recompute `+`/`−` from buffer vs cached HEAD (typing).
    case deltaOnly
}

/// Process-free HEAD blob cache — `git show` is expensive; typing only needs the blob once.
enum GitHeadContentCache: Sendable {
    /// Mutable map guarded by `lock` (`@unchecked Sendable` for Swift 6 globals).
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var map: [String: String] = [:]
    }
    private static let box = Box()

    static func contents(of file: URL) -> String {
        let path = file.standardizedFileURL.path
        box.lock.lock()
        if let hit = box.map[path] {
            box.lock.unlock()
            return hit
        }
        box.lock.unlock()
        let value = GitCLI.headFileContents(of: file)
        box.lock.lock()
        box.map[path] = value
        box.lock.unlock()
        return value
    }

    static func invalidate(url: URL? = nil) {
        box.lock.lock()
        if let url {
            box.map.removeValue(forKey: url.standardizedFileURL.path)
        } else {
            box.map.removeAll(keepingCapacity: false)
        }
        box.lock.unlock()
    }
}

@MainActor
enum GitFileStatus {
    /// Async snapshot: git Process work + Myers lineDiff never run on the main actor.
    static func snapshot(
        for url: URL?,
        buffer: String?,
        previous: GitFileSnapshot,
        mode: GitSnapshotRefresh
    ) async -> GitFileSnapshot {
        guard let url else { return .empty }
        let key = url.standardizedFileURL
        guard GitCLI.gitExecutable != nil else { return .empty }

        let sessionDirty = LineChangeTracker.shared.dirtyLines(for: key).count
        let bufferDirty = DocumentRegistry.shared.isDirty(key)
        // Prefer explicit buffer (caller passes live editor text); fall back to registry.
        let afterText = buffer ?? DocumentRegistry.shared.contentIfOpen(key)

        // Typing path: never spawn git status/branch — only +/− from cached HEAD.
        // If we have no prior in-repo meta yet, do one full snapshot instead.
        if mode == .deltaOnly, previous.inRepo {
            let (added, removed) = await lineDeltaAsync(file: key, after: afterText)
            var next = previous
            next.sessionDirtyLines = sessionDirty
            next.bufferDirty = bufferDirty
            next.added = added
            next.removed = removed
            return next
        }

        return await fullSnapshot(key: key, after: afterText,
                                  sessionDirty: sessionDirty, bufferDirty: bufferDirty)
    }

    private static func fullSnapshot(
        key: URL,
        after: String?,
        sessionDirty: Int,
        bufferDirty: Bool
    ) async -> GitFileSnapshot {
        // Capture for Sendable hop.
        let path = key
        let afterCopy = after
        let sess = sessionDirty
        let dirty = bufferDirty

        return await cancellableDetached { () -> GitFileSnapshot in
            guard !Task.isCancelled,
                  GitCLI.repositoryRoot(containing: path) != nil else {
                return GitFileSnapshot(
                    inRepo: false, pathStatus: .notInRepo, branch: nil,
                    ahead: nil, behind: nil,
                    sessionDirtyLines: sess, bufferDirty: dirty,
                    added: 0, removed: 0
                )
            }
            let status = GitCLI.pathStatus(of: path)
            if Task.isCancelled { return .empty }
            let branch = GitCLI.currentBranch(containing: path)
            if Task.isCancelled { return .empty }
            let ab = GitCLI.aheadBehind(containing: path)
            if Task.isCancelled { return .empty }
            let delta: (Int, Int)
            if status == .clean && !dirty && sess == 0 {
                delta = (0, 0)
            } else {
                delta = lineDeltaSync(file: path, after: afterCopy)
            }
            return GitFileSnapshot(
                inRepo: true,
                pathStatus: status,
                branch: branch,
                ahead: ab?.ahead,
                behind: ab?.behind,
                sessionDirtyLines: sess,
                bufferDirty: dirty,
                added: delta.0,
                removed: delta.1
            )
        }
    }

    private static func lineDeltaAsync(file: URL, after: String?) async -> (Int, Int) {
        let path = file
        let afterCopy = after
        return await cancellableDetached { () -> (Int, Int) in
            if Task.isCancelled { return (0, 0) }
            return lineDeltaSync(file: path, after: afterCopy)
        }
    }

    /// Detached git work with cancellation propagated in: detached tasks do
    /// not inherit it, so without the handler a superseded refresh keeps
    /// spawning git subprocesses to completion and refresh storms pile up
    /// concurrent chains. Bodies check `Task.isCancelled` between subprocess
    /// steps; the caller discards the result of a cancelled refresh.
    private static func cancellableDetached<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        let work = Task.detached(priority: .utility, operation: body)
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// `+` / `−` vs cached HEAD (or empty for untracked). Pure CPU + optional one `git show`.
    nonisolated static func lineDeltaSync(file: URL, after: String?) -> (added: Int, removed: Int) {
        let before = GitHeadContentCache.contents(of: file)
        let afterText: String
        if let after {
            afterText = after
        } else {
            afterText = GitCLI.workingTreeContents(of: file) ?? ""
        }
        if before == afterText { return (0, 0) }
        // Status-bar only: skip full Myers on enormous buffers (freeze risk).
        // Cap is tighter than TextDiff's 30k-line hard stop.
        let beforeLines = countDiffLines(before)
        let afterLines = countDiffLines(afterText)
        if beforeLines + afterLines > 8_000 {
            // Coarse: whole-file replace estimate, still better than hanging UI.
            return (afterLines, beforeLines)
        }
        let r = lineDiff(before: before, after: afterText)
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
    let onClose: () -> Void
    /// Called after a successful commit (marks already re-anchored).
    var onCommitted: (() -> Void)? = nil

    @State private var message: String = ""
    @State private var isBusy = false
    @State private var errorText: String?
    @State private var successHash: String?
    @State private var pushNote: String?
    @State private var pushError: String?
    /// Loaded once off-main on appear — a computed `GitCLI.currentBranch`
    /// spawned a git Process on every body re-render (each keystroke).
    @State private var branch: String?
    @FocusState private var messageFocused: Bool

    private var fileName: String { fileURL.lastPathComponent }

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
            messageFocused = true
            loadBranchAndSuggestion()
        }
    }

    /// Branch + prefilled message need 2–4 git Processes — run them off-main
    /// so opening the sheet doesn't stall the UI.
    private func loadBranchAndSuggestion() {
        let url = fileURL
        let name = fileName
        let wantSuggestion = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Session gutter marks live on the main actor — read before hopping.
        let sessionDirty = LineChangeTracker.shared.dirtyLines(for: url)
        Task.detached(priority: .userInitiated) {
            let branchName = GitCLI.currentBranch(containing: url)
            var suggested: String?
            if wantSuggestion {
                let status = GitCLI.pathStatus(of: url)
                // Prefer session marks (what the user just edited); fall back to
                // git diff line numbers when marks are empty but the file is modified.
                var dirty = sessionDirty
                if dirty.isEmpty, status == .modified || status == .clean {
                    dirty = GitCLI.changedLineNumbers(of: url)
                }
                suggested = GitCommitMessage.suggested(
                    fileName: name, pathStatus: status, dirtyLines: dirty)
            }
            await MainActor.run {
                branch = branchName
                if let suggested,
                   message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    message = suggested
                }
            }
        }
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
            errorText = String(localized: "Commit message is empty.")
            return
        }
        isBusy = true
        errorText = nil
        // 1) Flush buffer so git sees current text.
        do {
            try DocumentRegistry.shared.saveNow(fileURL)
        } catch {
            isBusy = false
            errorText = String(localized: "Save failed: \(error.localizedDescription)")
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
        alert.messageText = String(localized: "Push to remote?")
        let branchName = branch ?? String(localized: "current branch")
        alert.informativeText = String(localized: "This runs `git push` for “\(branchName)” using your system credentials (Keychain / SSH agent). Network access required.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Push"))
        alert.addButton(withTitle: String(localized: "Cancel"))
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
    /// Meta check + confirm + `git push`, with every git Process off the main
    /// actor — a network push used to freeze the UI for its whole duration.
    /// Alerts surface on main; refreshes ride `.gitRepositoryDidChange`.
    static func run(for fileURL: URL) {
        Task.detached(priority: .userInitiated) {
            guard GitCLI.repositoryRoot(containing: fileURL) != nil else {
                await presentError(String(localized: "Not inside a git repository."))
                return
            }
            let branch = GitCLI.currentBranch(containing: fileURL) ?? String(localized: "current branch")
            let ab = GitCLI.aheadBehind(containing: fileURL)
            guard await confirm(branch: branch, ab: ab) else { return }

            // Credential prompts are handled by the system helper / ssh-agent
            // outside this process.
            let result = GitCLI.push(containing: fileURL)
            await MainActor.run {
                NotificationCenter.default.post(name: .gitRepositoryDidChange, object: fileURL)
                switch result {
                case .success(let note):
                    let done = NSAlert()
                    done.messageText = String(localized: "Push completed")
                    done.informativeText = note
                    done.alertStyle = .informational
                    done.addButton(withTitle: String(localized: "OK"))
                    done.runModal()
                case .failure(let err):
                    presentError(err.message)
                }
            }
        }
    }

    private static func confirm(branch: String, ab: (ahead: Int, behind: Int)?) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Push to remote?")
        var info = String(localized: "Branch: \(branch)\nRuns `git push` with system credentials (Keychain / SSH).")
        if let ab {
            if ab.ahead == 0 {
                info += String(localized: "\n\nNothing to push (0 commits ahead of upstream).")
            } else {
                info += String(localized: "\n\n\(ab.ahead) commit(s) ahead")
                if ab.behind > 0 { info += String(localized: ", \(ab.behind) behind") }
                info += "."
            }
        } else {
            info += String(localized: "\n\nNo upstream configured — git will report the error if push cannot proceed.")
        }
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Push"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Push failed")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
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
    /// Async: git Process on a utility queue; MainActor only for dirty flags.
    static func snapshotAsync(
        workspaceRoots: [URL],
        openURLs: [URL]
    ) async -> GitWorkspaceSnapshot {
        // Snapshot dirty state on main, then leave.
        var dirtySession: [URL: Int] = [:]
        var dirtyBuffer: [URL: Bool] = [:]
        for u in openURLs {
            let k = u.standardizedFileURL
            dirtySession[k] = LineChangeTracker.shared.dirtyLines(for: k).count
            dirtyBuffer[k] = DocumentRegistry.shared.isDirty(k)
        }
        let roots = workspaceRoots.map { $0.standardizedFileURL }
        let open = openURLs.map { $0.standardizedFileURL }

        return await Task.detached(priority: .utility) {
            snapshotOffMain(
                workspaceRoots: roots,
                openURLs: open,
                sessionDirty: dirtySession,
                bufferDirty: dirtyBuffer
            )
        }.value
    }

    /// Build a snapshot from adopted workspace roots + currently open docs.
    /// Uses one `git status` per repository (not per file). Prefer `snapshotAsync`
    /// from UI so Process work is not on the main actor.
    static func snapshot(
        workspaceRoots: [URL],
        openURLs: [URL] = DocumentRegistry.shared.openURLs
    ) -> GitWorkspaceSnapshot {
        var dirtySession: [URL: Int] = [:]
        var dirtyBuffer: [URL: Bool] = [:]
        for u in openURLs {
            let k = u.standardizedFileURL
            dirtySession[k] = LineChangeTracker.shared.dirtyLines(for: k).count
            dirtyBuffer[k] = DocumentRegistry.shared.isDirty(k)
        }
        return snapshotOffMain(
            workspaceRoots: workspaceRoots.map { $0.standardizedFileURL },
            openURLs: openURLs.map { $0.standardizedFileURL },
            sessionDirty: dirtySession,
            bufferDirty: dirtyBuffer
        )
    }

    /// Pure git + provided dirty maps (safe off MainActor).
    nonisolated private static func snapshotOffMain(
        workspaceRoots: [URL],
        openURLs: [URL],
        sessionDirty: [URL: Int],
        bufferDirty: [URL: Bool]
    ) -> GitWorkspaceSnapshot {
        guard GitCLI.gitExecutable != nil else {
            return GitWorkspaceSnapshot(
                sections: [], openDirty: [], hasAnyRepo: false,
                hasWorkspaces: !workspaceRoots.isEmpty
            )
        }
        let roots = workspaceRoots
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
                    sessionDirtyLines: sessionDirty[key] ?? 0,
                    bufferDirty: bufferDirty[key] ?? false
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
            let key = open
            guard !changedURLs.contains(key) else { continue }
            guard isMarkdown(key) else { continue }
            guard let ws = owningWorkspace(key, among: roots) else { continue }
            let bufDirty = bufferDirty[key] ?? false
            let sessionLines = sessionDirty[key] ?? 0
            guard bufDirty || sessionLines > 0 else { continue }
            // Must be inside a git repo to be interesting here.
            guard let repo = GitCLI.repositoryRoot(containing: key) else { continue }
            let status = GitCLI.pathStatus(of: key)
            openDirty.append(GitChangedFile(
                url: key,
                displayPath: displayPath(of: key, workspace: ws, repo: repo),
                pathStatus: status == .notInRepo ? .clean : status,
                sessionDirtyLines: sessionLines,
                bufferDirty: bufDirty
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

    nonisolated private static func isMarkdown(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "textbundle"
    }

    /// Longest workspace prefix that contains `url`.
    nonisolated private static func owningWorkspace(_ url: URL, among workspaces: [URL]) -> URL? {
        let path = url.standardizedFileURL.path
        return workspaces
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max(by: { $0.path.count < $1.path.count })
    }

    nonisolated private static func displayPath(of file: URL, workspace: URL, repo: URL) -> String {
        let relWS = GitCLI.relativePath(of: file, to: workspace)
        if !relWS.isEmpty { return relWS }
        return GitCLI.relativePath(of: file, to: repo)
    }

    /// Before/after for the unified diff sheet (git sidebar).
    /// HEAD blob vs open buffer (if any) else working tree; deleted → empty after.
    /// Async: `git show` / status Processes never run on the main actor.
    static func diffSheetContent(for file: URL) async -> DiffSheetContent {
        // Buffer state lives on the main actor — capture before hopping.
        let open = DocumentRegistry.shared.contentIfOpen(file)
        let bufferDirty = open != nil && DocumentRegistry.shared.isDirty(file)
        return await Task.detached(priority: .userInitiated) {
            let before = GitCLI.headFileContents(of: file)
            let after: String
            let sideLabel: String
            if let open {
                after = open
                sideLabel = bufferDirty ? "HEAD → buffer (unsaved)" : "HEAD → buffer"
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
        }.value
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
