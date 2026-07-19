import Foundation

/// Offline vault engine (plan 10, stage 4): when EditMD is not running,
/// `editmdctl` answers the wikillm commands itself with the SAME pure engine
/// the app compiles (`LinkGraphEngine`, `WikiLinkCore`, `vaultLintFindings`,
/// `runWorkspaceSearch`, …) and the same `.editmd/link-index.json`.
///
/// Rules:
/// - Offline answers are current DISK truth: every graph query revalidates
///   the persisted index against (mtime, size) and re-parses only changed
///   files — the same cost model as the app's full scan.
/// - The refreshed index is saved back, so the next query (and the app's
///   next launch) start warm.
/// - `index rebuild` refuses while EditMD is running: the app maintains the
///   index itself, and the socket commands see live buffers.
enum OfflineVault {

    /// Commands the offline engine can serve (`cmd` wire names).
    static let capableCommands: Set<String> = [
        "index.status", "index.rebuild",
        "links.outgoing", "links.backlinks", "links.resolve",
        "outline", "lint.workspace", "lint.file",
        "tags.list", "tags.files", "frontmatter.get", "search",
    ]

    static func canHandle(_ cmd: String) -> Bool {
        capableCommands.contains(cmd)
    }

    // MARK: - Entry

    static func run(_ request: ControlRequest, rootOverride: String?) -> ControlResponse {
        let id = request.id
        do {
            switch request.cmd {
            case "index.rebuild":
                let root = try discoverRoot(request: request, rootOverride: rootOverride)
                let graph = buildGraph(root: root)
                return .success(id: id, data: .object([
                    "root": .string(root.path),
                    "files": .int(graph.outgoing.count),
                    "links": .int(graph.outgoing.values.reduce(0) { $0 + $1.count }),
                    "reparsed": .int(graph.filesParsed),
                    "resolvedFresh": .int(graph.freshResolves),
                    "savedTo": .string(LinkIndexPersistence.indexFileURL(root: root).path),
                ]))

            case "index.status":
                let root = try discoverRoot(request: request, rootOverride: rootOverride)
                let file = LinkIndexPersistence.indexFileURL(root: root)
                var obj: [String: JSONValue] = [
                    "mode": .string("offline"),
                    "ready": .bool(false),
                    "roots": .array([.string(root.path)]),
                ]
                if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                   let modified = attrs[.modificationDate] as? Date {
                    let cache = LinkIndexPersistence.load(root: root)
                    obj["ready"] = .bool(!cache.isEmpty)
                    obj["files"] = .int(cache.count)
                    obj["links"] = .int(cache.values.reduce(0) { $0 + $1.links.count })
                    obj["persisted"] = .object([
                        "path": .string(file.path),
                        "ageSeconds": .int(Int(Date().timeIntervalSince(modified))),
                    ])
                } else {
                    obj["persisted"] = .null
                }
                return .success(id: id, data: .object(obj))

            case "links.outgoing", "links.backlinks":
                let root = try discoverRoot(request: request, rootOverride: rootOverride)
                let url = try pathArg(request, root: root)
                let graph = buildGraph(root: root)
                if request.cmd == "links.outgoing" {
                    let links = graph.outgoing[url] ?? []
                    return .success(id: id, data: .object([
                        "path": .string(url.path),
                        "count": .int(links.count),
                        "links": .array(links.map(controlLinkJSON)),
                    ]))
                }
                let edges = graph.backlinks[url] ?? []
                return .success(id: id, data: .object([
                    "path": .string(url.path),
                    "count": .int(edges.count),
                    "backlinks": .array(edges.map(controlBacklinkJSON)),
                ]))

            case "links.resolve":
                guard let target = request.argString("target"), !target.isEmpty else {
                    throw CLIError("links.resolve requires a target")
                }
                let root = try discoverRoot(request: request, rootOverride: rootOverride)
                let index = WikiLinkCore.buildIndex(roots: [root])
                let matches = WikiLinkCore.matches(for: target, in: index)
                let fromDir = request.argString("from").map {
                    URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL
                }
                return .success(id: id, data: controlResolvePayload(
                    target: target, matches: matches, fromDir: fromDir))

            case "outline":
                let root = try discoverRoot(request: request, rootOverride: rootOverride)
                let url = try pathArg(request, root: root)
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return .success(id: id,
                                data: controlOutlinePayload(path: url.path, text: text))

            case "frontmatter.get":
                let root = try discoverRoot(request: request, rootOverride: rootOverride)
                let url = try pathArg(request, root: root)
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return .success(id: id,
                                data: controlFrontmatterPayload(path: url.path, text: text))

            case "lint.workspace", "lint.file":
                let root = try discoverRoot(request: request, rootOverride: rootOverride)
                let graph = buildGraph(root: root)
                let homes = Set([homeDocument(in: root)?.standardizedFileURL].compactMap { $0 })
                let snapshot = LinkIndexSnapshot(
                    standardizedOutgoing: graph.outgoing,
                    backlinks: graph.backlinks,
                    headings: graph.headings,
                    skippedOversizedCount: graph.skipped,
                    roots: [root],
                    homeDocuments: homes)
                if request.cmd == "lint.file" {
                    let url = try pathArg(request, root: root)
                    let findings = vaultLintFindings(for: url, index: snapshot)
                    return .success(id: id, data: .object([
                        "path": .string(url.path),
                        "count": .int(findings.count),
                        "findings": .array(findings.map(controlFindingJSON)),
                    ]))
                }
                let limit = max(1, request.argInt("limit") ?? 500)
                let findings = vaultLintFindings(index: snapshot)
                return .success(id: id, data: .object([
                    "total": .int(findings.count),
                    "returned": .int(min(limit, findings.count)),
                    "findings": .array(findings.prefix(limit).map(controlFindingJSON)),
                ]))

            case "tags.list", "tags.files":
                let root = try discoverRoot(request: request, rootOverride: rootOverride)
                let tags = scanWorkspaceTags(roots: [root])
                if request.cmd == "tags.list" {
                    return .success(id: id, data: .object([
                        "count": .int(tags.count),
                        "tags": .object(Dictionary(uniqueKeysWithValues:
                            tags.map { ($0.key, JSONValue.int($0.value.count)) })),
                    ]))
                }
                guard let tag = request.argString("tag"), !tag.isEmpty else {
                    throw CLIError("tags.files requires a tag")
                }
                let normalized = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
                let files = tags[normalized] ?? tags["#" + normalized] ?? []
                return .success(id: id, data: .object([
                    "tag": .string(normalized),
                    "count": .int(files.count),
                    "files": .array(files.map(\.path).sorted().map { .string($0) }),
                ]))

            case "search":
                guard let raw = request.argString("query"),
                      !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw CLIError("search requires a query")
                }
                let root = try discoverRoot(request: request, rootOverride: rootOverride)
                let tags = scanWorkspaceTags(roots: [root])
                let limit = max(1, request.argInt("limit") ?? 50)
                let query = parseSearchQuery(raw)
                let metas = collectSearchFileMetas(roots: [root], tagIndex: tags)
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
                return .success(id: id, data: controlSearchPayload(query: raw, run: run))

            default:
                return .failure(id: id, error: "offline engine cannot handle \(request.cmd)")
            }
        } catch let err as CLIError {
            return .failure(id: id, error: err.description)
        } catch {
            return .failure(id: id, error: String(describing: error))
        }
    }

    // MARK: - Graph build (same pipeline as the app's full scan)

    struct Graph {
        var outgoing: [URL: [OutgoingLink]] = [:]
        var backlinks: [URL: [BacklinkEdge]] = [:]
        var headings: [URL: [String]] = [:]
        var skipped = 0
        var filesParsed = 0
        var freshResolves = 0
    }

    static func buildGraph(root: URL) -> Graph {
        let seed = LinkIndexPersistence.load(root: root)
        let scanned = LinkGraphEngine.scanWorkspaceOutgoing(
            roots: [root], cache: seed)
        let wikiIndex = WikiLinkCore.buildIndex(roots: [root])
        let fingerprint = LinkGraphEngine.resolveEnvironmentFingerprint(
            roots: [root], wikiIndex: wikiIndex, paths: scanned.environment.paths)

        var graph = Graph()
        graph.skipped = scanned.skipped
        graph.filesParsed = scanned.filesScanned
        graph.headings = scanned.headings
        var updatedCache = scanned.newCache
        for (source, links) in scanned.outgoing {
            if let hit = updatedCache[source],
               hit.resolveFingerprint == fingerprint,
               let cached = hit.resolvedLinks {
                graph.outgoing[source] = cached
                continue
            }
            let result = LinkGraphEngine.resolveScannedLinks(
                links, source: source, roots: [root],
                vaultFallback: nil, wikiIndex: wikiIndex,
                environment: scanned.environment)
            graph.outgoing[source] = result.links
            graph.freshResolves += 1
            if result.cacheable, var entry = updatedCache[source] {
                entry.resolvedLinks = result.links
                entry.resolveFingerprint = fingerprint
                updatedCache[source] = entry
            }
        }
        graph.backlinks = LinkGraphEngine.projectBacklinks(from: graph.outgoing)
        LinkIndexPersistence.save(cache: updatedCache, root: root)
        return graph
    }

    // MARK: - Root discovery

    /// Workspace root for an offline command: an EXPLICIT root (`--root` or
    /// the command's root argument) is authoritative — `index rebuild` must
    /// work on a fresh vault that has no marker yet. Otherwise walk up from
    /// the path argument (or the caller's cwd) to the nearest directory
    /// holding a `.editmd/` or `.obsidian/` marker.
    static func discoverRoot(request: ControlRequest, rootOverride: String?) throws -> URL {
        if let explicit = rootOverride ?? request.argString("root") {
            let url = URL(fileURLWithPath: explicit).standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else {
                throw CLIError("workspace root is not a directory: \(url.path)")
            }
            return url
        }
        let startPath = request.argString("path")
            ?? FileManager.default.currentDirectoryPath
        var probe = URL(fileURLWithPath: startPath).standardizedFileURL
        var isDir: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: probe.path, isDirectory: &isDir)
             && isDir.boolValue) {
            probe = probe.deletingLastPathComponent()
        }
        for _ in 0..<64 {
            for marker in [LinkIndexPersistence.directoryName, ".obsidian"] {
                if FileManager.default.fileExists(
                    atPath: probe.appendingPathComponent(marker).path) {
                    return probe
                }
            }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        throw CLIError(
            "no workspace root found (looked for .editmd/ or .obsidian/ upward from "
            + "\(startPath)) — pass --root PATH")
    }

    /// A path argument that must exist AND lie inside `root` — the offline
    /// counterpart of the socket's `checkScope`, so an explicit `--root` is
    /// authoritative for path commands too (not just `index rebuild`).
    private static func pathArg(_ request: ControlRequest, root: URL) throws -> URL {
        guard let path = request.argString("path"), !path.isEmpty else {
            throw CLIError("\(request.cmd) requires a path when EditMD is not running")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let r = root.standardizedFileURL.path
        // Firmlink-canonicalized containment: a missing in-vault file keeps
        // its `/private/…` prefix while the root collapses to `/tmp`, so a raw
        // prefix check would wrongly reject it. Same helper the socket uses.
        guard pathIsContained(url.path, in: r) else {
            // Same error token as the socket's `checkScope`, so agents that
            // branch on it behave identically online and offline.
            throw CLIError("outside-active-workspace: \(url.path) is not under \(r)")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError("file not found: \(url.path)")
        }
        return url
    }
}
