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

    /// Rejects files that belong to a different adopted workspace than the
    /// one the index currently covers. Files outside every root pass through:
    /// loose files legitimately appear in the single-file map.
    private static func checkScope(_ url: URL, index: LinkIndex) throws {
        let roots = index.snapshot().roots
        guard !roots.isEmpty else { return }
        let path = url.standardizedFileURL.path
        let insideActive = roots.contains {
            path == $0.path || path.hasPrefix($0.path + "/")
        }
        if insideActive { return }
        let owningOther = WorkspaceModel.shared.workspaces.contains {
            let r = $0.url.standardizedFileURL.path
            return path == r || path.hasPrefix(r + "/")
        }
        if owningOther {
            throw ControlError(
                "outside-active-workspace: the index covers one workspace at a "
                + "time — open a file from that workspace first")
        }
    }

    // MARK: - links.outgoing / links.backlinks

    static func linksOutgoing(_ request: ControlRequest) throws -> Dispatched {
        let url = try fileURL(for: request)
        let index = try readyLinkIndex()
        try checkScope(url, index: index)
        let links = index.outgoingLinks(for: url)
        return .data(.object([
            "path": .string(url.standardizedFileURL.path),
            "count": .int(links.count),
            "links": .array(links.map(controlLinkJSON)),
        ]))
    }

    static func linksBacklinks(_ request: ControlRequest) throws -> Dispatched {
        let url = try fileURL(for: request)
        let index = try readyLinkIndex()
        try checkScope(url, index: index)
        let edges = index.backlinkEdges(for: url)
        return .data(.object([
            "path": .string(url.standardizedFileURL.path),
            "count": .int(edges.count),
            "backlinks": .array(edges.map(controlBacklinkJSON)),
        ]))
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
        let url = try fileURL(for: request)
        let buffered = DocumentRegistry.shared.contentIfOpen(url)
        let requestID = request.id
        return .deferred {
            let text = buffered
                ?? ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            return .success(id: requestID,
                            data: controlOutlinePayload(path: url.path, text: text))
        }
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
        let url = try fileURL(for: request)
        let index = try readyLinkIndex()
        try checkScope(url, index: index)
        let snapshot = index.snapshot()
        let requestID = request.id
        return .deferred {
            let findings = vaultLintFindings(for: url.standardizedFileURL,
                                             index: snapshot)
            return .success(id: requestID, data: .object([
                "path": .string(url.standardizedFileURL.path),
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

    static func tagsList(_ request: ControlRequest) -> Dispatched {
        let workspace = WorkspaceModel.shared
        workspace.ensureTagIndex()
        let tags = workspace.tagIndex
        return .data(.object([
            "count": .int(tags.count),
            "tags": .object(Dictionary(uniqueKeysWithValues:
                tags.map { ($0.key, JSONValue.int($0.value.count)) })),
        ]))
    }

    static func tagsFiles(_ request: ControlRequest) throws -> Dispatched {
        guard let tag = request.argString("tag"), !tag.isEmpty else {
            throw ControlError("tags.files requires args.tag")
        }
        let workspace = WorkspaceModel.shared
        workspace.ensureTagIndex()
        let normalized = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
        let files = workspace.tagIndex[normalized]
            ?? workspace.tagIndex["#" + normalized]
            ?? []
        return .data(.object([
            "tag": .string(normalized),
            "count": .int(files.count),
            "files": .array(files.map(\.path).sorted().map { .string($0) }),
        ]))
    }

    // MARK: - frontmatter.get

    static func frontmatterGet(_ request: ControlRequest) throws -> Dispatched {
        let url = try fileURL(for: request)
        let buffered = DocumentRegistry.shared.contentIfOpen(url)
        let requestID = request.id
        return .deferred {
            let text = buffered
                ?? ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            return .success(id: requestID,
                            data: controlFrontmatterPayload(path: url.path, text: text))
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
        // Tag filters (`#tag`) work when the tag index is warm; kick it lazily.
        WorkspaceModel.shared.ensureTagIndex()
        let tags = WorkspaceModel.shared.tagIndex
        let limit = max(1, request.argInt("limit") ?? 50)
        let requestID = request.id
        return .deferred {
            let query = parseSearchQuery(raw)
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
