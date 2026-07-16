import Foundation

// Disk cores of the file/folder move machinery: pure nonisolated statics
// with injectable move primitives, plus the transaction error types.
// Extracted from WorkspaceModel.swift.

struct FileMoveResult: Equatable, Sendable {
    let source: URL
    let destination: URL
}

typealias FileMoveItemOperation = @Sendable (
    _ source: URL, _ destination: URL
) throws -> Void

/// Filesystem state left behind when a move transaction could not be rolled
/// back completely. Callers use the file flags to relocate any parked/open
/// document to the path that actually survived; the sidecar flags make a split
/// document/review state explicit instead of hiding a second rollback failure.
struct FileMoveRollbackState: Equatable, Sendable {
    let move: FileMoveResult
    let expectedReviewSidecar: Bool
    let fileAtSource: Bool
    let fileAtDestination: Bool
    let reviewSidecarAtSource: Bool
    let reviewSidecarAtDestination: Bool

    var fileRemainsAtDestination: Bool {
        fileAtDestination && !fileAtSource
    }

    var isFullyRolledBack: Bool {
        fileAtSource && !fileAtDestination
            && (!expectedReviewSidecar
                || (reviewSidecarAtSource && !reviewSidecarAtDestination))
    }
}

enum FileMoveError: LocalizedError, Equatable, Sendable {
    case sourceNoLongerExists
    case unsupportedSource
    case destinationNotFolder
    case alreadyExists(String)
    case moveInProgress
    case rollbackFailed([FileMoveRollbackState])

    var errorDescription: String? {
        switch self {
        case .sourceNoLongerExists:
            return "Файл больше не существует по прежнему пути."
        case .unsupportedSource:
            return "Можно перемещать только файлы, которые EditMD показывает в сайдбаре."
        case .destinationNotFolder:
            return "Папка назначения больше не существует."
        case .alreadyExists(let name):
            return "В папке назначения уже существует «\(name)»."
        case .moveInProgress:
            return "Этот файл уже перемещается."
        case .rollbackFailed(let states):
            let names = states.map { "«\($0.move.destination.lastPathComponent)»" }
                .joined(separator: ", ")
            return "Не удалось полностью отменить перенос \(names). Пути на диске были перепроверены; обновите открытые документы перед продолжением."
        }
    }
}

extension WorkspaceModel {
    nonisolated static func moveFolderOnDisk(
        from oldURL: URL,
        to newURL: URL,
        moveItem: FileMoveItemOperation = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: oldURL.path) else {
            // No filesystem mutation has started, so an existing destination
            // is not a survivor of this transaction — it may be an unrelated
            // folder and must never inherit the workspace identity.
            throw FolderRenameError.folderNoLongerExists
        }
        if fileManager.fileExists(atPath: newURL.path) {
            guard sameFilesystemItem(oldURL, newURL) else {
                throw FolderCreateError.alreadyExists(newURL.lastPathComponent)
            }
            try moveFolderThroughTemporary(
                from: oldURL, to: newURL, moveItem: moveItem)
            return
        }
        do {
            try moveItem(oldURL, newURL)
        } catch {
            throw FolderRenameError.diskFailure(
                probedFolderSurvivor([oldURL, newURL]))
        }
    }

    /// A case-insensitive volume reports `Notes` and `notes` as the same
    /// existing item. Move through a unique sibling so the final component is
    /// really updated, and surface the probed survivor if either later step
    /// and its recovery fail.
    nonisolated static func moveFolderThroughTemporary(
        from oldURL: URL,
        to newURL: URL,
        moveItem: FileMoveItemOperation
    ) throws {
        var temporaryURL: URL
        repeat {
            temporaryURL = oldURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".editmd-rename-\(UUID().uuidString)",
                    isDirectory: true)
        } while FileManager.default.fileExists(atPath: temporaryURL.path)

        do {
            try moveItem(oldURL, temporaryURL)
        } catch {
            throw FolderRenameError.diskFailure(
                probedFolderSurvivor([oldURL, newURL, temporaryURL]))
        }
        do {
            try moveItem(temporaryURL, newURL)
        } catch {
            do {
                try moveItem(temporaryURL, oldURL)
            } catch {
                throw FolderRenameError.diskFailure(
                    probedFolderSurvivor([oldURL, newURL, temporaryURL]))
            }
            throw FolderRenameError.diskFailure(oldURL)
        }
    }

    nonisolated private static func sameFilesystemItem(_ lhs: URL, _ rhs: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let lhsID = try? lhs.resourceValues(forKeys: keys).fileResourceIdentifier,
              let rhsID = try? rhs.resourceValues(forKeys: keys).fileResourceIdentifier,
              let lhsObject = lhsID as? NSObject,
              let rhsObject = rhsID as? NSObject else { return false }
        return lhsObject == rhsObject
    }

    /// Returns the actual on-disk spelling of one unambiguous survivor. On a
    /// case-insensitive volume the resource `name` reveals the real casing.
    nonisolated private static func probedFolderSurvivor(
        _ candidates: [URL]
    ) -> URL? {
        var survivors: [URL] = []
        for candidate in candidates where FileManager.default.fileExists(
            atPath: candidate.path) {
            let actualName = (try? candidate.resourceValues(
                forKeys: [.nameKey]))?.name
            let actual = actualName.map {
                candidate.deletingLastPathComponent()
                    .appendingPathComponent($0, isDirectory: true)
                    .standardizedFileURL
            } ?? candidate.standardizedFileURL
            if !survivors.contains(where: { sameFilesystemItem($0, actual) }) {
                survivors.append(actual)
            }
        }
        return survivors.count == 1 ? survivors[0] : nil
    }

    /// Internal disk core so tests can inject a failing move primitive and
    /// verify rollback reporting without relying on filesystem permissions.
    nonisolated static func moveFilesAndReviewSidecars(
        _ moves: [FileMoveResult],
        destinationFolder: URL,
        moveItem: FileMoveItemOperation = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) throws {
        let fileManager = FileManager.default
        guard AppState.isFolder(destinationFolder) else {
            throw FileMoveError.destinationNotFolder
        }

        // Preflight the whole batch. Duplicate basenames from different source
        // folders are a collision even when the destination is initially empty.
        var destinations = Set<String>()
        for move in moves {
            var sourceIsDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: move.source.path, isDirectory: &sourceIsDirectory) else {
                throw FileMoveError.sourceNoLongerExists
            }
            let sourceIsPackage = (try? move.source.resourceValues(
                forKeys: [.isPackageKey]))?.isPackage ?? false
            guard !sourceIsDirectory.boolValue || sourceIsPackage else {
                throw FileMoveError.unsupportedSource
            }
            guard destinations.insert(move.destination.path).inserted,
                  !fileManager.fileExists(atPath: move.destination.path) else {
                throw FileMoveError.alreadyExists(move.destination.lastPathComponent)
            }
            let newSidecar = ReviewSidecar.url(for: move.destination)
            if fileManager.fileExists(atPath: newSidecar.path) {
                throw FileMoveError.alreadyExists(newSidecar.lastPathComponent)
            }
        }

        var completed: [(move: FileMoveResult, hadReviewSidecar: Bool)] = []
        do {
            for move in moves {
                let hadReviewSidecar = try moveFileAndReviewSidecar(
                    from: move.source,
                    to: move.destination,
                    destinationFolder: destinationFolder,
                    moveItem: moveItem)
                completed.append((move, hadReviewSidecar))
            }
        } catch {
            var rollbackStates: [FileMoveRollbackState]
            if let moveError = error as? FileMoveError,
               case .rollbackFailed(let states) = moveError {
                rollbackStates = states
            } else {
                rollbackStates = []
            }

            for completedMove in completed.reversed() {
                do {
                    try rollbackCompletedMove(
                        completedMove.move,
                        hadReviewSidecar: completedMove.hadReviewSidecar,
                        moveItem: moveItem)
                } catch let rollbackError as FileMoveError {
                    if case .rollbackFailed(let states) = rollbackError {
                        rollbackStates.append(contentsOf: states)
                    } else {
                        rollbackStates.append(rollbackState(
                            for: completedMove.move,
                            expectedReviewSidecar: completedMove.hadReviewSidecar))
                    }
                } catch {
                    rollbackStates.append(rollbackState(
                        for: completedMove.move,
                        expectedReviewSidecar: completedMove.hadReviewSidecar))
                }
            }
            if !rollbackStates.isEmpty {
                var seen = Set<String>()
                let uniqueStates = rollbackStates.filter {
                    seen.insert($0.move.source.path).inserted
                }
                throw FileMoveError.rollbackFailed(uniqueStates)
            }
            throw error
        }
    }

    nonisolated private static func moveFileAndReviewSidecar(
        from source: URL,
        to destination: URL,
        destinationFolder: URL,
        moveItem: FileMoveItemOperation
    ) throws -> Bool {
        let fileManager = FileManager.default
        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else {
            throw FileMoveError.sourceNoLongerExists
        }
        let sourceIsPackage = (try? source.resourceValues(forKeys: [.isPackageKey]))?.isPackage
            ?? false
        guard !sourceIsDirectory.boolValue || sourceIsPackage else {
            throw FileMoveError.unsupportedSource
        }
        guard AppState.isFolder(destinationFolder) else {
            throw FileMoveError.destinationNotFolder
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileMoveError.alreadyExists(destination.lastPathComponent)
        }

        let oldSidecar = ReviewSidecar.url(for: source)
        let newSidecar = ReviewSidecar.url(for: destination)
        let hasSidecar = fileManager.fileExists(atPath: oldSidecar.path)
        if fileManager.fileExists(atPath: newSidecar.path) {
            throw FileMoveError.alreadyExists(newSidecar.lastPathComponent)
        }

        do {
            try moveItem(source, destination)
        } catch {
            let moveError = error
            let move = FileMoveResult(source: source, destination: destination)
            let state = rollbackState(
                for: move, expectedReviewSidecar: hasSidecar)
            guard state.isFullyRolledBack else {
                if state.fileRemainsAtDestination {
                    do {
                        try moveItem(destination, source)
                    } catch {
                        throw FileMoveError.rollbackFailed([
                            rollbackState(
                                for: move,
                                expectedReviewSidecar: hasSidecar)
                        ])
                    }
                    let recovered = rollbackState(
                        for: move, expectedReviewSidecar: hasSidecar)
                    guard recovered.isFullyRolledBack else {
                        throw FileMoveError.rollbackFailed([recovered])
                    }
                    throw moveError
                }
                throw FileMoveError.rollbackFailed([state])
            }
            throw moveError
        }
        guard hasSidecar else { return false }
        do {
            try moveItem(oldSidecar, newSidecar)
        } catch {
            let sidecarError = error
            // The file and its review marks are one logical document. Restore
            // the original file path when the sidecar cannot follow it.
            do {
                try moveItem(destination, source)
            } catch {
                throw FileMoveError.rollbackFailed([
                    rollbackState(for: FileMoveResult(
                        source: source, destination: destination),
                    expectedReviewSidecar: true)
                ])
            }
            let state = rollbackState(
                for: FileMoveResult(source: source, destination: destination),
                expectedReviewSidecar: true)
            guard state.isFullyRolledBack else {
                throw FileMoveError.rollbackFailed([state])
            }
            throw sidecarError
        }
        return true
    }

    nonisolated private static func rollbackCompletedMove(
        _ move: FileMoveResult,
        hadReviewSidecar: Bool,
        moveItem: FileMoveItemOperation
    ) throws {
        do {
            try moveItem(move.destination, move.source)
        } catch {
            throw FileMoveError.rollbackFailed([
                rollbackState(for: move, expectedReviewSidecar: hadReviewSidecar)
            ])
        }

        if hadReviewSidecar {
            let oldSidecar = ReviewSidecar.url(for: move.source)
            let newSidecar = ReviewSidecar.url(for: move.destination)
            do {
                try moveItem(newSidecar, oldSidecar)
            } catch {
                // Keep the document and its sidecar at the destination when
                // possible. Whether this recovery succeeds or not, report the
                // probed state instead of hiding either failure.
                do {
                    try moveItem(move.source, move.destination)
                } catch {
                    throw FileMoveError.rollbackFailed([
                        rollbackState(for: move, expectedReviewSidecar: true)
                    ])
                }
                throw FileMoveError.rollbackFailed([
                    rollbackState(for: move, expectedReviewSidecar: true)
                ])
            }
        }

        let state = rollbackState(
            for: move, expectedReviewSidecar: hadReviewSidecar)
        guard state.isFullyRolledBack else {
            throw FileMoveError.rollbackFailed([state])
        }
    }

    nonisolated private static func rollbackState(
        for move: FileMoveResult,
        expectedReviewSidecar: Bool
    ) -> FileMoveRollbackState {
        let fileManager = FileManager.default
        let oldSidecar = ReviewSidecar.url(for: move.source)
        let newSidecar = ReviewSidecar.url(for: move.destination)
        return FileMoveRollbackState(
            move: move,
            expectedReviewSidecar: expectedReviewSidecar,
            fileAtSource: fileManager.fileExists(atPath: move.source.path),
            fileAtDestination: fileManager.fileExists(atPath: move.destination.path),
            reviewSidecarAtSource: fileManager.fileExists(atPath: oldSidecar.path),
            reviewSidecarAtDestination: fileManager.fileExists(atPath: newSidecar.path))
    }
}
