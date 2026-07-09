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

    static let empty = GitFileSnapshot(
        inRepo: false, pathStatus: .notInRepo, branch: nil,
        ahead: nil, behind: nil, sessionDirtyLines: 0, bufferDirty: false
    )

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
        guard GitCLI.repositoryRoot(containing: key) != nil else {
            return GitFileSnapshot(
                inRepo: false, pathStatus: .notInRepo, branch: nil,
                ahead: nil, behind: nil,
                sessionDirtyLines: LineChangeTracker.shared.dirtyLines(for: key).count,
                bufferDirty: DocumentRegistry.shared.isDirty(key)
            )
        }
        let status = GitCLI.pathStatus(of: key)
        let branch = GitCLI.currentBranch(containing: key)
        let ab = GitCLI.aheadBehind(containing: key)
        return GitFileSnapshot(
            inRepo: true,
            pathStatus: status,
            branch: branch,
            ahead: ab?.ahead,
            behind: ab?.behind,
            sessionDirtyLines: LineChangeTracker.shared.dirtyLines(for: key).count,
            bufferDirty: DocumentRegistry.shared.isDirty(key)
        )
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
            messageFocused = true
            // Sensible default: file name without extension as stub (user edits).
            if message.isEmpty {
                message = ""
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

// MARK: - Status-bar chip

struct GitStatusChip: View {
    let snapshot: GitFileSnapshot
    let onCommit: () -> Void
    let onPush: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if let branch = snapshot.branch {
                Text(branch)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !snapshot.statusCaption.isEmpty, snapshot.statusCaption != "clean" {
                Text(snapshot.statusCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(snapshot.pathStatus == .clean ? Color.secondary : Color.orange)
            }

            if let ahead = snapshot.ahead, ahead > 0 {
                Text("↑\(ahead)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .help("\(ahead) commit(s) to push")
            }

            if snapshot.canCommit {
                Button("Commit", action: onCommit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .help("Commit this file…")
            }

            if snapshot.inRepo {
                Button("Push", action: onPush)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: snapshot.canPush && (snapshot.ahead ?? 1) > 0 ? .medium : .regular))
                    .foregroundStyle(
                        (snapshot.ahead ?? 0) > 0 ? Color.accentColor : Color.secondary
                    )
                    .help("Push to remote…")
            }
        }
    }
}
