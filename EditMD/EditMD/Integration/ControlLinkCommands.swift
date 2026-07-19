import AppKit
import Foundation

/// Plan 10 «wikillm ready»: control-socket commands that hand the vault
/// graph to an agent — outgoing/backlinks/resolve, outline, vault-lint,
/// tags, frontmatter, index status. The agent asks EditMD instead of
/// walking and re-parsing the vault itself.
///
/// Scope contract: answers reflect the ACTIVE workspace only
/// (`WorkspaceModel.linkIndexRoots`); a path under another adopted workspace
/// fails with `outside-active-workspace`. Main phase reads published
/// dictionaries (no stats); everything disk-bound runs in the deferred
/// phase on the socket thread. Protocol output is English-only.
extension ControlRouter {

    // MARK: - Readiness

    /// The link graph, if usable. A command is a consumer: when nobody has
    /// built the index yet this kicks the lazy build and reports honest
    /// progress instead of blocking the socket. Never restarts a completed
    /// index (tests seed `LinkIndex.shared` and must not trigger a real scan).
    private static func readyLinkIndex() throws -> LinkIndex {
        let index = LinkIndex.shared
        if index.hasCompletedFullScan { return index }
        index.ensureIndex()
        let pct = index.scanProgress.map { Int(($0 * 100).rounded()) } ?? 0
        throw ControlError("link index not ready (indexing \(pct)%) — retry shortly")
    }

    /// Roots that define the active-workspace scope: what the index actually
    /// covers, falling back to the adopted active workspace when the index has
    /// not published roots yet (cold app — a workspace is adopted but the scan
    /// never ran). Empty only in true loose / no-workspace mode.
    static func activeScopeRoots() -> [URL] {
        let indexRoots = LinkIndex.shared.snapshot().roots
        if !indexRoots.isEmpty { return indexRoots }
        return WorkspaceModel.shared.linkIndexRoots.map(\.standardizedFileURL)
    }

    /// Pure scope predicate: is `path` outside EVERY root? Empty roots → not
    /// outside (loose mode). Testable without touching any singleton.
    nonisolated static func isOutsideScope(_ path: String, roots: [URL]) -> Bool {
        guard !roots.isEmpty else { return false }
        return !roots.contains { pathIsContained(path, in: $0.path) }
    }

    /// Enforces the active-workspace scope on a file path — any path outside
    /// the active workspace is rejected (not only paths in another adopted
    /// workspace), so every path-based vault-graph command keeps the
    /// documented `outside-active-workspace` contract even before the index
    /// has warmed. Main-safe: pure path math over live state, no disk I/O.
    private static func checkScope(_ url: URL) throws {
        if isOutsideScope(url.standardizedFileURL.path, roots: activeScopeRoots()) {
            throw ControlError(
                "outside-active-workspace: the index covers one workspace at a "
                + "time — open a file from that workspace first")
        }
    }

    /// Main-phase snapshot of "this file is known to exist without a disk
    /// stat": open in a buffer, or mid path-mutation. The deferred phase stats
    /// the disk only when this is false — so `fileExists` never runs on main
    /// (two-phase contract) yet a genuinely missing in-scope file still gets a
    /// `file not found` reply instead of a misleading empty payload.
    static func knownPresentOnMain(_ url: URL) -> Bool {
        DocumentRegistry.shared.contentIfOpen(url) != nil
            || AppState.shared.isPathMutationInProgress(at: url)
    }

    /// Deferred-phase existence gate. `knownPresent` is captured on main.
    /// `nonisolated`: runs on the socket thread, stats disk only, no main state.
    nonisolated static func existsInDeferred(_ url: URL, knownPresent: Bool) -> Bool {
        knownPresent
            || FileManager.default.fileExists(atPath: url.standardizedFileURL.path)
    }

    // MARK: - links.outgoing / links.backlinks

    static func linksOutgoing(_ request: ControlRequest) throws -> Dispatched {
        let url = try targetURL(for: request)
        try checkScope(url)
        let index = try readyLinkIndex()
        let std = url.standardizedFileURL
        let links = index.outgoingLinks(for: url)
        // A file scanned into the graph provably exists (a graph KEY, even with
        // zero links). Stat the disk only when it is not a key.
        let present = index.outgoing[std] != nil || knownPresentOnMain(url)
        let requestID = request.id
        return .deferred {
            guard existsInDeferred(std, knownPresent: present) else {
                return .failure(id: requestID, error: "file not found: \(std.path)")
            }
            return .success(id: requestID, data: .object([
                "path": .string(std.path),
                "count": .int(links.count),
                "links": .array(links.map(controlLinkJSON)),
            ]))
        }
    }

    static func linksBacklinks(_ request: ControlRequest) throws -> Dispatched {
        let url = try targetURL(for: request)
        try checkScope(url)
        let index = try readyLinkIndex()
        let std = url.standardizedFileURL
        let edges = index.backlinkEdges(for: url)
        // A page with no inbound links is a valid target; the graph KEY proves
        // existence, backlinks do not. Stat only when it is not a key.
        let present = index.outgoing[std] != nil || knownPresentOnMain(url)
        let requestID = request.id
        return .deferred {
            guard existsInDeferred(std, knownPresent: present) else {
                return .failure(id: requestID, error: "file not found: \(std.path)")
            }
            return .success(id: requestID, data: .object([
                "path": .string(std.path),
                "count": .int(edges.count),
                "backlinks": .array(edges.map(controlBacklinkJSON)),
            ]))
        }
    }

    // MARK: - links.resolve

    /// Same rules as navigation: basename match over the active roots,
    /// sibling of `--from` wins a tie. The resolver is an actor — the socket
    /// thread bridges with a bounded semaphore (it is a dedicated thread,
    /// never a cooperative-pool one, so blocking it is safe).
    static func linksResolve(_ request: ControlRequest) throws -> Dispatched {
        guard let target = request.argString("target"), !target.isEmpty else {
            throw ControlError("links.resolve requires args.target")
        }
        var mutableRoots = LinkIndex.shared.snapshot().roots
        if mutableRoots.isEmpty { mutableRoots = WorkspaceModel.shared.linkIndexRoots }
        guard !mutableRoots.isEmpty else {
            throw ControlError("links.resolve: no workspace adopted")
        }
        let roots = mutableRoots
        let fromDir = request.argString("from").map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
                .deletingLastPathComponent().standardizedFileURL
        }
        let requestID = request.id
        return .deferred {
            final class Box: @unchecked Sendable { var matches: [URL] = [] }
            let box = Box()
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await WikiLinkResolver.shared.setRoots(roots)
                box.matches = await WikiLinkResolver.shared.resolve(target)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 10) == .success else {
                return .failure(id: requestID, error: "links.resolve timed out")
            }
            return .success(id: requestID, data: controlResolvePayload(
                target: target, matches: box.matches, fromDir: fromDir))
        }
    }

    // MARK: - outline

    static func outlineCommand(_ request: ControlRequest) throws -> Dispatched {
        let url = try targetURL(for: request)
        try checkScope(url)
        let buffered = DocumentRegistry.shared.contentIfOpen(url)
        let mutating = AppState.shared.isPathMutationInProgress(at: url)
        let std = url.standardizedFileURL
        let requestID = request.id
        return .deferred {
            guard let text = fileText(buffered: buffered, mutating: mutating, url: std) else {
                return .failure(id: requestID, error: "file not found: \(std.path)")
            }
            return .success(id: requestID,
                            data: controlOutlinePayload(path: std.path, text: text))
        }
    }

    /// Deferred-phase file text: the open buffer, else disk. `nil` (→ caller
    /// replies `file not found`) only when the file is neither open, nor
    /// mid-mutation, nor on disk — never a silent empty payload for a missing
    /// file. Off-main: `String(contentsOf:)` must not run on the main actor.
    nonisolated private static func fileText(buffered: String?, mutating: Bool, url: URL) -> String? {
        if let buffered { return buffered }
        if let disk = try? String(contentsOf: url, encoding: .utf8) { return disk }
        return mutating ? "" : nil
    }

    // MARK: - lint

    static func lintWorkspace(_ request: ControlRequest) throws -> Dispatched {
        let index = try readyLinkIndex()
        let snapshot = index.snapshot()
        let limit = max(1, request.argInt("limit") ?? 500)
        let requestID = request.id
        return .deferred {
            // Home documents need a directory listing per root — socket
            // thread, never main (same shape as VaultLintModel.scheduleRun).
            let homes = Set(snapshot.roots.compactMap {
                homeDocument(in: $0)?.standardizedFileURL
            })
            let full = LinkIndexSnapshot(
                standardizedOutgoing: snapshot.outgoing,
                backlinks: snapshot.backlinks,
                headings: snapshot.headings,
                skippedOversizedCount: snapshot.skippedOversizedCount,
                roots: snapshot.roots,
                homeDocuments: homes)
            let findings = vaultLintFindings(index: full)
            return .success(id: requestID, data: .object([
                "total": .int(findings.count),
                "returned": .int(min(limit, findings.count)),
                "findings": .array(findings.prefix(limit).map(controlFindingJSON)),
            ]))
        }
    }

    static func lintFile(_ request: ControlRequest) throws -> Dispatched {
        let url = try targetURL(for: request)
        try checkScope(url)
        let index = try readyLinkIndex()
        let std = url.standardizedFileURL
        let present = index.outgoing[std] != nil || knownPresentOnMain(url)
        let snapshot = index.snapshot()
        let requestID = request.id
        return .deferred {
            guard existsInDeferred(std, knownPresent: present) else {
                return .failure(id: requestID, error: "file not found: \(std.path)")
            }
            let findings = vaultLintFindings(for: std, index: snapshot)
            return .success(id: requestID, data: .object([
                "path": .string(std.path),
                "count": .int(findings.count),
                "findings": .array(findings.map(controlFindingJSON)),
            ]))
        }
    }


    // MARK: - index.status

    static func indexStatus(_ request: ControlRequest) -> Dispatched {
        let index = LinkIndex.shared
        let snapshot = index.snapshot()
        var obj: [String: JSONValue] = [
            "ready": .bool(index.hasCompletedFullScan),
            "scanning": .bool(index.isScanning),
            "files": .int(snapshot.outgoing.count),
            "links": .int(snapshot.outgoing.values.reduce(0) { $0 + $1.count }),
            "roots": .array(snapshot.roots.map { .string($0.path) }),
        ]
        if let progress = index.scanProgress {
            obj["progress"] = .double((progress * 100).rounded() / 100)
        }
        guard let root = snapshot.roots.first else {
            return .data(.object(obj))
        }
        // Persisted-file stat happens on the socket thread.
        let requestID = request.id
        let partial = obj
        return .deferred {
            var out = partial
            let file = LinkIndexPersistence.indexFileURL(root: root)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let modified = attrs[.modificationDate] as? Date {
                out["persisted"] = .object([
                    "path": .string(file.path),
                    "ageSeconds": .int(Int(Date().timeIntervalSince(modified))),
                ])
            } else {
                out["persisted"] = .null
            }
            return .success(id: requestID, data: .object(out))
        }
    }

    // MARK: - tags

    /// Tags are scanned fresh in the deferred phase over the ACTIVE root, not
    /// read from `WorkspaceModel.tagIndex`: that index is populated async (a
    /// cold `tags list` would honestly answer count:0 while the scan runs) and
    /// covers all adopted workspaces, not the active one. `scanWorkspaceTags`
    /// is the same pure walk the app uses — synchronous and correctly scoped.
    /// Cost note: this is a full vault walk PER CALL (no cache); acceptable for
    /// an occasional agent query, unlike the UI path which caches by epoch.
    static func tagsList(_ request: ControlRequest) -> Dispatched {
        let roots = WorkspaceModel.shared.linkIndexRoots
        let requestID = request.id
        return .deferred {
            let tags = scanWorkspaceTags(roots: roots)
            return .success(id: requestID, data: .object([
                "count": .int(tags.count),
                "tags": .object(Dictionary(uniqueKeysWithValues:
                    tags.map { ($0.key, JSONValue.int($0.value.count)) })),
            ]))
        }
    }

    static func tagsFiles(_ request: ControlRequest) throws -> Dispatched {
        guard let tag = request.argString("tag"), !tag.isEmpty else {
            throw ControlError("tags.files requires args.tag")
        }
        let roots = WorkspaceModel.shared.linkIndexRoots
        let normalized = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        let requestID = request.id
        return .deferred {
            let tags = scanWorkspaceTags(roots: roots)
            let files = tags[normalized] ?? tags["#" + normalized] ?? []
            return .success(id: requestID, data: .object([
                "tag": .string(normalized),
                "count": .int(files.count),
                "files": .array(files.map(\.path).sorted().map { .string($0) }),
            ]))
        }
    }

    // MARK: - frontmatter.get

    static func frontmatterGet(_ request: ControlRequest) throws -> Dispatched {
        let url = try targetURL(for: request)
        try checkScope(url)
        let buffered = DocumentRegistry.shared.contentIfOpen(url)
        let mutating = AppState.shared.isPathMutationInProgress(at: url)
        let std = url.standardizedFileURL
        let requestID = request.id
        return .deferred {
            guard let text = fileText(buffered: buffered, mutating: mutating, url: std) else {
                return .failure(id: requestID, error: "file not found: \(std.path)")
            }
            return .success(id: requestID,
                            data: controlFrontmatterPayload(path: std.path, text: text))
        }
    }

    // MARK: - search

    /// Workspace full-text search over the ACTIVE workspace roots — the same
    /// pure engine the search sidebar uses. Runs entirely in the deferred
    /// phase (directory walk + content reads must not touch main).
    static func searchCommand(_ request: ControlRequest) throws -> Dispatched {
        guard let raw = request.argString("query"),
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ControlError("search requires args.query")
        }
        let roots = WorkspaceModel.shared.linkIndexRoots
        guard !roots.isEmpty else {
            throw ControlError("search: no workspace adopted")
        }
        let limit = max(1, request.argInt("limit") ?? 50)
        let requestID = request.id
        return .deferred {
            let query = parseSearchQuery(raw)
            // A tag walk (up to 2 KB per file) is a second vault pass — run it
            // ONLY when the query actually filters by `tag:`. A plain text
            // search stays one walk (metas). Fresh over the active root so the
            // filter is correct on the first call (not the async, all-workspace
            // WorkspaceModel.tagIndex).
            let tags = query.tags.isEmpty ? [:] : scanWorkspaceTags(roots: roots)
            let metas = collectSearchFileMetas(roots: roots, tagIndex: tags)
            var options = SearchRunOptions.default
            options.maxResultFiles = limit
            let run = runWorkspaceSearch(
                query: query,
                files: metas,
                contentProvider: {
                    loadSearchFileContent(meta: $0, cache: nil,
                                          maxBytes: options.maxFileBytes)
                },
                options: options)
            return .success(id: requestID,
                            data: controlSearchPayload(query: raw, run: run))
        }
    }
}
