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
    panel.title = files.count == 1 ? "Переместить файл" : "Переместить файлы"
    panel.message = files.count == 1
        ? "Выберите папку назначения для «\(first.lastPathComponent)»."
        : "Выберите общую папку назначения для \(files.count) выбранных файлов."
    panel.prompt = "Переместить"
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

        let sidecarCanStayAtSource = !state.reviewSidecarAtDestination
            && (!state.expectedReviewSidecar || state.reviewSidecarAtSource)
        let sidecarCanStayAtDestination = !state.reviewSidecarAtSource
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
                    ? "Перемещаем «\(files[0].lastPathComponent)»…"
                    : "Перемещаем файлы (\(files.count))…"
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
                    ? "Не удалось переместить файл"
                    : "Не удалось переместить файлы")
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
