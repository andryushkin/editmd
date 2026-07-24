import SwiftUI
import AppKit
import UniformTypeIdentifiers

// File-move machinery shared by the sidebar, folder card and drag-and-drop.
// Extracted from FolderInfo.swift.

@MainActor
@discardableResult
func promptForFileMove(_ file: URL, workspace: WorkspaceModel) -> Bool {
    promptForFileMove([file], workspace: workspace)
}

@MainActor
@discardableResult
func promptForFileMove(_ rawFiles: [URL], workspace: WorkspaceModel) -> Bool {
    let files = uniqueStandardizedFiles(rawFiles)
    guard let first = files.first else { return false }
    let panel = NSOpenPanel()
    panel.title = files.count == 1
        ? String(localized: "Move File") : String(localized: "Move Files")
    panel.message = files.count == 1
        ? String(localized: "Choose a destination folder for “\(first.lastPathComponent)”.")
        : String(localized: "Choose a common destination folder for the \(files.count) selected files.")
    panel.prompt = String(localized: "Move")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.directoryURL = first.deletingLastPathComponent()
    guard panel.runModal() == .OK, let folder = panel.url else { return false }
    performFileMoves(files, to: folder, workspace: workspace)
    return true
}

/// Shared completion path for context-menu and drag-and-drop moves.
@MainActor
func performFileMove(_ file: URL, to folder: URL, workspace: WorkspaceModel) {
    performFileMoves([file], to: folder, workspace: workspace)
}

private struct PreparedFileMove {
    let source: URL
    let presentation: AppState.FilePresentationState
    let preparation: DocumentMovePreparation?
}

private struct FileMovePathMutation {
    let source: URL
    let destination: URL
    let sourceToken: UUID
    let destinationToken: UUID

    var tokens: Set<UUID> { [sourceToken, destinationToken] }
}

/// Where a parked presentation can safely resume after a move rollback failed.
/// Ambiguous disk or sidecar state deliberately has no automatic reopen path.
enum FileMoveRecoveryResolution: Equatable, Sendable {
    case source
    case destination(URL)
    case unresolved
}

/// Both spellings of a case-only rename resolve to the same directory entry
/// on a case-insensitive volume, so a file/sidecar case mismatch after a
/// failed rollback is still one coherent document — not a split state.
private func isCaseOnlyAlias(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.deletingLastPathComponent().path == rhs.deletingLastPathComponent().path
        && lhs.lastPathComponent != rhs.lastPathComponent
        && lhs.lastPathComponent.caseInsensitiveCompare(rhs.lastPathComponent)
            == .orderedSame
}

func fileMoveRecoveryResolutions(
    for rawFiles: [URL],
    after error: Error
) -> [URL: FileMoveRecoveryResolution] {
    var resolutions: [URL: FileMoveRecoveryResolution] = [:]
    for file in rawFiles {
        resolutions[file.standardizedFileURL] = .source
    }

    guard let moveError = error as? FileMoveError,
          case .rollbackFailed(let states) = moveError else {
        return resolutions
    }

    for state in states {
        let source = state.move.source.standardizedFileURL
        guard resolutions[source] != nil else { continue }

        let caseOnly = isCaseOnlyAlias(state.move.source, state.move.destination)
        // Case-only: the sidecar is accounted for under either spelling.
        let sidecarAccountedFor = !state.expectedReviewSidecar
            || state.reviewSidecarAtSource || state.reviewSidecarAtDestination
        let sidecarCanStayAtSource = caseOnly
            ? sidecarAccountedFor
            : !state.reviewSidecarAtDestination
                && (!state.expectedReviewSidecar || state.reviewSidecarAtSource)
        let sidecarCanStayAtDestination = caseOnly
            ? sidecarAccountedFor
            : !state.reviewSidecarAtSource
                && (!state.expectedReviewSidecar || state.reviewSidecarAtDestination)

        if state.fileAtSource, !state.fileAtDestination,
           sidecarCanStayAtSource {
            resolutions[source] = .source
        } else if !state.fileAtSource, state.fileAtDestination,
                  sidecarCanStayAtDestination {
            resolutions[source] = .destination(
                state.move.destination.standardizedFileURL)
        } else {
            resolutions[source] = .unresolved
        }
    }
    return resolutions
}

/// Shared transactional completion path for context-menu and drag-and-drop.
/// Every open document is parked before disk I/O, then the whole presentation
/// topology is restored at either all new paths or all original paths.
@MainActor
func performFileMoves(_ rawFiles: [URL], to rawFolder: URL, workspace: WorkspaceModel) {
    let folder = rawFolder.standardizedFileURL
    let files = uniqueStandardizedFiles(rawFiles).filter {
        $0.deletingLastPathComponent() != folder
    }
    guard !files.isEmpty else { return }
    Task { @MainActor in
        do {
            try await LongRunningOperationCenter.shared.run(
                title: files.count == 1
                    ? String(localized: "Moving “\(files[0].lastPathComponent)”…")
                    : String(localized: "Moving files (\(files.count))…")
            ) {
                // Acquire the global FIFO permit before installing path gates.
                // A transaction queued behind an earlier rename must not keep
                // gates that the earlier transaction can relocate underneath
                // its still-stale source arguments.
                let review = ReviewModel.shared
                let reviewToken = await review.beginPathMutation()
                var reviewMutationResolved = false
                defer {
                    if !reviewMutationResolved {
                        review.cancelPathMutation(reviewToken)
                    }
                }

                let registry = DocumentRegistry.shared
                let appState = AppState.shared
                let pathMutations = files.map { source in
                    let destination = folder
                        .appendingPathComponent(source.lastPathComponent)
                        .standardizedFileURL
                    return FileMovePathMutation(
                        source: source,
                        destination: destination,
                        sourceToken: appState.beginPathMutation(at: source),
                        destinationToken: appState.beginPathMutation(at: destination))
                }
                let routeTokensBySource = Dictionary(
                    uniqueKeysWithValues: pathMutations.map {
                        ($0.source, $0.tokens)
                    })
                var discardedRouteTokens = Set<UUID>()
                defer {
                    appState.finishPathMutations(
                        Set(pathMutations.flatMap(\.tokens)),
                        discardingRouteIDs: discardedRouteTokens)
                }

                var prepared: [PreparedFileMove] = []
                var destinationPreparations: [URL: DocumentMovePreparation] = [:]
                do {
                    // Reserve every future path before extracting any live
                    // source model. If one destination is occupied, every
                    // editor remains attached to its ordinary registry entry.
                    for mutation in pathMutations {
                        destinationPreparations[mutation.source] = try registry
                            .reserveMoveDestination(mutation.destination)
                    }

                    // No suspension in this pass: the whole batch becomes
                    // registry-owned before the first dirty snapshot write.
                    // A control/agent edit cannot slip into a later source
                    // while an earlier source is persisting off-main.
                    for source in files {
                        let preparation = try registry.beginMovePreparation(source)
                        prepared.append(PreparedFileMove(
                            source: source,
                            presentation: appState.detachFileForMove(source),
                            preparation: preparation))
                    }
                    for item in prepared {
                        if let preparation = item.preparation {
                            try await registry.persistMovePreparation(preparation)
                        }
                    }
                    let moves = try await workspace.moveFilesOnDisk(files, to: folder)
                    let destinations = Dictionary(
                        uniqueKeysWithValues: moves.map { ($0.source, $0.destination) })
                    for reservation in destinationPreparations.values {
                        registry.discardMovePreparation(reservation)
                    }
                    for move in moves {
                        registry.relocatePreparedDocument(
                            from: move.source, to: move.destination)
                        appState.relocateFile(from: move.source, to: move.destination)
                        DocumentHistory.shared.relocateFile(
                            from: move.source, to: move.destination)
                    }
                    review.completePathMutation(
                        reviewToken,
                        relocatingFiles: moves.map {
                            ReviewModel.FileRelocation(
                                from: $0.source, to: $0.destination)
                        })
                    reviewMutationResolved = true
                    restorePreparedFiles(
                        prepared,
                        destinations: destinations,
                        routeTokens: routeTokensBySource)
                } catch {
                    var resolutions = fileMoveRecoveryResolutions(
                        for: files, after: error)
                    let pathsToProbe = pathMutations.flatMap {
                        [$0.source, $0.destination]
                    }
                    let existingPaths = await Task.detached(
                        priority: .userInitiated
                    ) {
                        Set(pathsToProbe.filter {
                            FileManager.default.fileExists(atPath: $0.path)
                        })
                    }.value
                    for source in files {
                        switch resolutions[source] ?? .source {
                        case .source where !existingPaths.contains(source):
                            resolutions[source] = .unresolved
                        case .destination(let destination)
                            where !existingPaths.contains(destination):
                            resolutions[source] = .unresolved
                        default:
                            break
                        }
                    }
                    // Keep every destination reserved through the awaited
                    // filesystem probe. Release them only now, immediately
                    // before applying the final source/destination outcomes.
                    for reservation in destinationPreparations.values {
                        registry.discardMovePreparation(reservation)
                    }
                    var destinations: [URL: URL] = [:]
                    var reviewRelocations: [ReviewModel.FileRelocation] = []
                    var unresolved = Set<URL>()

                    for item in prepared {
                        switch resolutions[item.source] ?? .source {
                        case .source:
                            registry.cancelMovePreparation(item.preparation)
                        case .destination(let destination):
                            registry.relocatePreparedDocument(
                                from: item.source, to: destination)
                            appState.relocateFile(
                                from: item.source, to: destination)
                            DocumentHistory.shared.relocateFile(
                                from: item.source, to: destination)
                            destinations[item.source] = destination
                            reviewRelocations.append(.init(
                                from: item.source, to: destination))
                        case .unresolved:
                            registry.discardMovePreparation(item.preparation)
                            unresolved.insert(item.source)
                        }
                    }

                    var reviewDroppedPaths = unresolved
                    for mutation in pathMutations {
                        switch resolutions[mutation.source] ?? .source {
                        case .source:
                            if !existingPaths.contains(mutation.destination) {
                                discardedRouteTokens.insert(
                                    mutation.destinationToken)
                                reviewDroppedPaths.insert(
                                    mutation.destination)
                            }
                        case .destination:
                            break
                        case .unresolved:
                            discardedRouteTokens.formUnion(mutation.tokens)
                            reviewDroppedPaths.formUnion([
                                mutation.source, mutation.destination
                            ])
                        }
                    }
                    let isRollbackFailure: Bool = {
                        guard let moveError = error as? FileMoveError,
                              case .rollbackFailed = moveError else {
                            return false
                        }
                        return true
                    }()
                    if !reviewRelocations.isEmpty
                        || !reviewDroppedPaths.isEmpty
                        || isRollbackFailure {
                        review.completePathMutation(
                            reviewToken,
                            relocatingFiles: reviewRelocations,
                            droppingFiles: Array(reviewDroppedPaths))
                    } else {
                        review.cancelPathMutation(reviewToken)
                    }
                    reviewMutationResolved = true
                    restorePreparedFiles(
                        prepared,
                        destinations: destinations,
                        skipping: unresolved,
                        routeTokens: routeTokensBySource)
                    throw error
                }
            }
        } catch {
            presentFolderError(
                error,
                title: files.count == 1
                    ? String(localized: "Could not move the file")
                    : String(localized: "Could not move the files"))
        }
    }
}

private func uniqueStandardizedFiles(_ rawFiles: [URL]) -> [URL] {
    var seen = Set<URL>()
    return rawFiles.compactMap { raw in
        let file = raw.standardizedFileURL
        return seen.insert(file).inserted ? file : nil
    }
}

// MARK: - Rename

@MainActor
@discardableResult
func promptForFileRename(_ file: URL, workspace: WorkspaceModel) -> Bool {
    let source = file.standardizedFileURL
    guard let name = promptForNewName(
        title: String(localized: "Rename File"),
        message: String(localized: "Enter a new name for “\(source.lastPathComponent)”."),
        defaultName: source.lastPathComponent,
        confirmTitle: String(localized: "Rename")
    ) else { return false }
    performFileRename(source, to: name, workspace: workspace)
    return true
}

/// Renames a single sidebar document in place. Mirrors `performFileMoves` for
/// one file: any open presentation is parked before the disk rename and
/// restored at the new path, so the registry, autosave and watcher stay
/// coherent. On failure everything is restored at the original path.
@MainActor
func performFileRename(_ rawFile: URL, to rawName: String, workspace: WorkspaceModel) {
    let source = rawFile.standardizedFileURL
    let destination: URL
    do {
        // Same derivation renameFileOnDisk uses — the gates and the registry
        // reservation below must guard the URL the disk core will target.
        destination = try WorkspaceModel.renameDestination(
            for: source, newName: rawName)
    } catch {
        presentFolderError(error, title: String(localized: "Could not rename the file"))
        return
    }
    guard destination != source else { return }

    Task { @MainActor in
        do {
            try await LongRunningOperationCenter.shared.run(
                title: String(localized: "Renaming “\(source.lastPathComponent)”…")
            ) {
                let review = ReviewModel.shared
                let reviewToken = await review.beginPathMutation()
                var reviewResolved = false
                defer { if !reviewResolved { review.cancelPathMutation(reviewToken) } }

                let registry = DocumentRegistry.shared
                let appState = AppState.shared
                let sourceToken = appState.beginPathMutation(at: source)
                let destinationToken = appState.beginPathMutation(at: destination)
                var discardedRouteTokens = Set<UUID>()
                defer {
                    appState.finishPathMutations(
                        [sourceToken, destinationToken],
                        discardingRouteIDs: discardedRouteTokens)
                }

                // Reserve the destination; the defer releases it on any throw
                // before the relocation consumes it (mirrors performFileMoves).
                let reservation = try registry.reserveMoveDestination(destination)
                var reservationDiscarded = false
                @MainActor func discardReservation() {
                    guard !reservationDiscarded else { return }
                    registry.discardMovePreparation(reservation)
                    reservationDiscarded = true
                }
                defer { discardReservation() }

                // Extract the live source model before any disk write. A throw
                // here is handled by the outer defers; nothing is parked yet.
                let preparation = try registry.beginMovePreparation(source)
                let presentation = appState.detachFileForMove(source)
                do {
                    if let preparation {
                        try await registry.persistMovePreparation(preparation)
                    }
                    let newURL = try await workspace.renameFileOnDisk(source, to: rawName)
                    discardReservation()
                    registry.relocatePreparedDocument(from: source, to: newURL)
                    appState.relocateFile(from: source, to: newURL)
                    DocumentHistory.shared.relocateFile(from: source, to: newURL)
                    review.completePathMutation(
                        reviewToken,
                        relocatingFiles: [.init(from: source, to: newURL)])
                    reviewResolved = true
                    appState.restoreFilePresentation(
                        presentation, at: newURL,
                        ignoringPathMutationIDs: [sourceToken, destinationToken])
                } catch {
                    // Mirror performFileMoves' recovery: decide from the
                    // rollback report where the file actually survived, and
                    // confirm against the disk before acting on it.
                    var resolution = fileMoveRecoveryResolutions(
                        for: [source], after: error)[source] ?? .source
                    // Exact-spelling probe: after a case-only failure a plain
                    // fileExists reports both names as present.
                    let existingPaths = await Task.detached(
                        priority: .userInitiated
                    ) {
                        Set([source, destination].filter {
                            WorkspaceModel.directoryEntryExists($0)
                        })
                    }.value
                    switch resolution {
                    case .source where !existingPaths.contains(source):
                        resolution = .unresolved
                    case .destination(let survivor)
                        where !existingPaths.contains(survivor):
                        resolution = .unresolved
                    default:
                        break
                    }
                    // Keep the destination reserved through the awaited probe;
                    // release it only now, before applying the outcome.
                    discardReservation()

                    var reviewRelocations: [ReviewModel.FileRelocation] = []
                    var reviewDroppedPaths: [URL] = []
                    switch resolution {
                    case .source:
                        registry.cancelMovePreparation(preparation)
                        // Discard the destination route only when nothing
                        // actually lives there — an unrelated existing file
                        // (alreadyExists) must keep its history and window.
                        if !existingPaths.contains(destination) {
                            discardedRouteTokens.insert(destinationToken)
                            reviewDroppedPaths.append(destination)
                        }
                        appState.restoreFilePresentation(
                            presentation, at: source,
                            ignoringPathMutationIDs: [sourceToken])
                    case .destination(let survivor):
                        registry.relocatePreparedDocument(
                            from: source, to: survivor)
                        appState.relocateFile(from: source, to: survivor)
                        DocumentHistory.shared.relocateFile(
                            from: source, to: survivor)
                        reviewRelocations.append(.init(
                            from: source, to: survivor))
                        appState.restoreFilePresentation(
                            presentation, at: survivor,
                            ignoringPathMutationIDs: [sourceToken, destinationToken])
                    case .unresolved:
                        registry.discardMovePreparation(preparation)
                        discardedRouteTokens.formUnion(
                            [sourceToken, destinationToken])
                        reviewDroppedPaths.append(contentsOf: [source, destination])
                    }
                    let isRollbackFailure: Bool = {
                        guard let moveError = error as? FileMoveError,
                              case .rollbackFailed = moveError else { return false }
                        return true
                    }()
                    if !reviewRelocations.isEmpty
                        || !reviewDroppedPaths.isEmpty
                        || isRollbackFailure {
                        review.completePathMutation(
                            reviewToken,
                            relocatingFiles: reviewRelocations,
                            droppingFiles: reviewDroppedPaths)
                    } else {
                        review.cancelPathMutation(reviewToken)
                    }
                    reviewResolved = true
                    throw error
                }
            }
        } catch {
            presentFolderError(
                error, title: String(localized: "Could not rename the file"))
        }
    }
}

// MARK: - Move to Trash

/// Confirm and move a folder (and everything inside) to the system Trash.
/// Refused while any open document lives inside — matching disk-rename — so the
/// registry, autosave and file watcher never point at a vanished path. Returns
/// `true` when the user confirmed and the trash operation was started.
@MainActor
@discardableResult
func confirmAndMoveFolderToTrash(_ rawFolder: URL, workspace: WorkspaceModel) -> Bool {
    let folder = rawFolder.standardizedFileURL
    guard FileManager.default.fileExists(atPath: folder.path) else { return false }

    func refuseOpenDocuments(_ count: Int) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Close the open files inside “\(folder.lastPathComponent)” first.")
        alert.informativeText = String(localized: "\(Int(count)) open documents live inside this folder. Close them before moving it to the Trash.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    let openCount = workspace.openDocumentCount(
        inside: folder,
        among: AppState.openDocumentURLsForDiskMutation())
    guard openCount == 0 else {
        refuseOpenDocuments(openCount)
        return false
    }

    let alert = NSAlert()
    alert.messageText = String(localized: "Move the folder “\(folder.lastPathComponent)” to the Trash?")
    var info = String(localized: "The folder and everything inside it will be moved to the Trash. You can restore it later.")
    // Live entries are refused above; this warns about recently CLOSED
    // documents whose unsaved buffers only live in the registry session cache.
    if DocumentRegistry.shared.hasUnsavedChanges(inside: folder) {
        info += "\n\n" + String(localized: "Some files have unsaved changes that will be discarded.")
    }
    alert.informativeText = info
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "Move to Trash"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return false }

    // The modal spun the run loop: an in-flight move into this folder or a
    // control-socket open may have landed an open document inside meanwhile.
    // Re-check before touching the disk.
    let recheck = workspace.openDocumentCount(
        inside: folder,
        among: AppState.openDocumentURLsForDiskMutation())
    guard recheck == 0 else {
        refuseOpenDocuments(recheck)
        return false
    }

    Task { @MainActor in
        do {
            try await LongRunningOperationCenter.shared.run(
                title: String(localized: "Moving “\(folder.lastPathComponent)” to the Trash…")
            ) {
                // Trashing can degrade to copy+delete on slow/network volumes
                // — never synchronously on the main actor.
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.trashItem(
                        at: folder, resultingItemURL: nil)
                }.value
                finishFolderTrash(folder, workspace: workspace)
            }
        } catch {
            presentFolderError(
                error, title: String(localized: "Could not move to the Trash"))
        }
    }
    return true
}

/// Post-trash cleanup, folder-wide twin of the per-file steps in
/// `confirmAndMoveFilesToTrash`: parked/cached registry models under the root
/// must not resurrect after Put Back, history and pending routes must not
/// navigate into the Trash, and change-tracking baselines are dropped.
@MainActor
private func finishFolderTrash(_ folder: URL, workspace: WorkspaceModel) {
    DocumentRegistry.shared.discardFolderCaches(at: [folder])
    // Also relocates the main window to Welcome when it pointed inside.
    AppState.shared.discardPathState(inside: [folder])
    LineChangeTracker.shared.forget(under: folder)
    workspace.forgetTrashedFolder(folder)
    NotificationCenter.default.post(name: .gitRepositoryDidChange, object: nil)
}

/// Confirm and move existing files to the system Trash (context menus).
/// Returns `true` when at least one path was trashed.
@MainActor
@discardableResult
func confirmAndMoveFilesToTrash(
    _ rawFiles: [URL],
    workspace: WorkspaceModel
) -> Bool {
    let files = uniqueStandardizedFiles(rawFiles).filter {
        FileManager.default.fileExists(atPath: $0.path)
    }
    guard !files.isEmpty else { return false }

    let hasDirty = files.contains { DocumentRegistry.shared.isDirty($0) }

    let alert = NSAlert()
    if files.count == 1 {
        let name = files[0].lastPathComponent
        alert.messageText = String(localized: "Move “\(name)” to the Trash?")
    } else {
        // Cast so String Catalog sees a stable Int format (not Int32).
        alert.messageText = String(localized: "Move \(Int(files.count)) items to the Trash?")
    }
    var info = String(localized: "You can restore them from the Trash later.")
    if hasDirty {
        info += "\n\n" + String(localized: "Some files have unsaved changes that will be discarded.")
    }
    alert.informativeText = info
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "Move to Trash"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return false }

    var trashed: [URL] = []
    var firstError: Error?
    for url in files {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            trashed.append(url)
        } catch {
            if firstError == nil { firstError = error }
        }
    }

    if !trashed.isEmpty {
        let app = AppState.shared
        for url in trashed {
            if app.currentURL?.standardizedFileURL == url {
                // Leave the editor — the path no longer exists on disk.
                app.openInMainWindow(nil)
            }
            LineChangeTracker.shared.forget(url: url)
            if workspace.isFavorite(url) { workspace.removeFavorite(url) }
            if workspace.isPinned(url) { workspace.unpin(url) }
            workspace.removeLoose(url)
        }
        workspace.noteFilesystemChange()
        NotificationCenter.default.post(name: .gitRepositoryDidChange, object: nil)
    }

    if let firstError {
        presentFolderError(
            firstError,
            title: String(localized: "Could not move to the Trash"))
    }
    return !trashed.isEmpty
}

@MainActor
private func restorePreparedFiles(
    _ prepared: [PreparedFileMove],
    destinations: [URL: URL],
    skipping skippedSources: Set<URL> = [],
    routeTokens: [URL: Set<UUID>] = [:]
) {
    // The globally focused presentation is reopened last, after the rest of
    // the batch can no longer steal focus from it.
    let ordered = prepared.filter {
        !skippedSources.contains($0.source)
    }.sorted { lhs, rhs in
        lhs.presentation.focus == .neither && rhs.presentation.focus != .neither
    }
    for item in ordered {
        AppState.shared.restoreFilePresentation(
            item.presentation,
            at: destinations[item.source] ?? item.source,
            ignoringPathMutationIDs: routeTokens[item.source] ?? [])
    }
}

private struct FileMoveDropTargetModifier: ViewModifier {
    @ObservedObject var workspace: WorkspaceModel
    let folder: URL
    let onMoveStarted: () -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [sidebarFileDragContentType], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first(where: {
                    $0.hasItemConformingToTypeIdentifier(sidebarFileDragContentType.identifier)
                }) else { return false }
                provider.loadDataRepresentation(
                    forTypeIdentifier: sidebarFileDragContentType.identifier
                ) { data, _ in
                    guard let data,
                          let payload = try? decodeSidebarFileDragPayload(data),
                          !payload.files.isEmpty else { return }
                    Task { @MainActor in
                        performFileMoves(payload.files, to: folder, workspace: workspace)
                        onMoveStarted()
                    }
                }
                return true
            }
    }
}

extension View {
    func fileMoveDropTarget(
        folder: URL,
        workspace: WorkspaceModel,
        onMoveStarted: @escaping () -> Void = {}
    ) -> some View {
        modifier(FileMoveDropTargetModifier(
            workspace: workspace,
            folder: folder,
            onMoveStarted: onMoveStarted))
    }
}
