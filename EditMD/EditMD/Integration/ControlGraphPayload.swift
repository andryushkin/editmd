import Foundation

// JSON payload builders shared by the app's control router and the offline
// editmdctl engine — ONE source of truth for the wire shapes (plan 10), so
// the two transports cannot drift. Pure Foundation; English-only protocol.

/// Resolution status of one outgoing link.
func controlLinkStatus(_ link: OutgoingLink) -> String {
    if let scheme = URL(string: link.rawTarget)?.scheme, !scheme.isEmpty {
        return "external"
    }
    if link.resolved != nil { return "resolved" }
    if link.candidates.count > 1 { return "ambiguous" }
    return "dead"
}

func controlLinkJSON(_ link: OutgoingLink) -> JSONValue {
    var o: [String: JSONValue] = [
        "kind": .string(link.kind.rawValue),
        "target": .string(link.rawTarget),
        "label": .string(link.label),
        "line": .int(link.line),
        "offset": .int(link.utf16Offset),
        "context": .string(link.context),
        "status": .string(controlLinkStatus(link)),
    ]
    if let heading = link.heading { o["heading"] = .string(heading) }
    if let resolved = link.resolved { o["path"] = .string(resolved.path) }
    if link.candidates.count > 1 {
        o["candidates"] = .array(link.candidates.map { .string($0.path) })
    }
    return .object(o)
}

func controlBacklinkJSON(_ edge: BacklinkEdge) -> JSONValue {
    .object([
        "source": .string(edge.source.path),
        "target": .string(edge.link.rawTarget),
        "line": .int(edge.link.line),
        "offset": .int(edge.link.utf16Offset),
        "context": .string(edge.link.context),
    ])
}

/// Findings serialize the structured payload, not the localized display
/// text — the protocol is English-only and the agent needs fields, not prose.
func controlFindingJSON(_ f: VaultLintFinding) -> JSONValue {
    var o: [String: JSONValue] = [
        "rule": .string(f.rule.rawValue),
        "severity": .string(f.severity.rawValue),
        "file": .string(f.file.path),
    ]
    if let line = f.line { o["line"] = .int(line) }
    if let offset = f.utf16Offset { o["offset"] = .int(offset) }
    if let suggestion = f.targetSuggestion { o["suggestion"] = .string(suggestion.path) }
    switch f.messagePayload {
    case let .deadWiki(target, _):
        o["target"] = .string(target)
    case let .ambiguousWiki(target, count):
        o["target"] = .string(target)
        o["matches"] = .int(count)
    case .selfLink:
        break
    case let .deadRelative(target),
         let .outsideWorkspace(target),
         let .deadImage(target):
        o["target"] = .string(target)
    case let .deadHeading(heading, target):
        o["target"] = .string(target)
        o["heading"] = .string(heading)
    case let .orphan(name):
        o["target"] = .string(name)
    }
    return .object(o)
}

/// Outline payload for one file's text.
func controlOutlinePayload(path: String, text: String) -> JSONValue {
    let items = markdownOutline(text)
    return .object([
        "path": .string(path),
        "count": .int(items.count),
        "outline": .array(items.map {
            .object([
                "level": .int($0.level),
                "title": .string($0.title),
                "offset": .int($0.markdownOffset),
            ])
        }),
    ])
}

/// Frontmatter payload for one file's text.
func controlFrontmatterPayload(path: String, text: String) -> JSONValue {
    guard let range = frontmatterRange(in: text) else {
        return .object([
            "path": .string(path),
            "present": .bool(false),
            "properties": .array([]),
        ])
    }
    let body = (text as NSString).substring(with: range.body)
    let properties = parseFrontmatterProperties(body)
    return .object([
        "path": .string(path),
        "present": .bool(true),
        "raw": .string(body),
        "properties": .array(properties.map { p in
            var o: [String: JSONValue] = [
                "key": .string(p.key),
                "value": .string(p.value),
            ]
            if p.isList {
                o["items"] = .array(p.items.map { .string($0) })
            }
            return .object(o)
        }),
    ])
}

/// `links.resolve` payload: navigation rules — unique match wins, otherwise
/// a sibling of `fromDir` breaks the tie.
func controlResolvePayload(target: String, matches: [URL], fromDir: URL?) -> JSONValue {
    var chosen: URL?
    if matches.count == 1 {
        chosen = matches[0]
    } else if let fromDir {
        chosen = matches.first {
            $0.deletingLastPathComponent().standardizedFileURL == fromDir
        }
    }
    var out: [String: JSONValue] = [
        "target": .string(target),
        "count": .int(matches.count),
        "matches": .array(matches.map { .string($0.path) }),
    ]
    out["path"] = chosen.map { .string($0.path) } ?? .null
    out["status"] = .string(
        matches.isEmpty ? "dead" : (chosen != nil ? "resolved" : "ambiguous"))
    return .object(out)
}

/// `search` payload over a finished pure run.
func controlSearchPayload(query rawQuery: String, run: SearchRunResult) -> JSONValue {
    var o: [String: JSONValue] = [
        "query": .string(rawQuery),
        "count": .int(run.files.count),
        "truncated": .bool(run.truncated),
        "files": .array(run.files.map { f in
            .object([
                "path": .string(f.url.path),
                "relativePath": .string(f.relativePath),
                "matchCount": .int(f.matchCount),
                "nameMatched": .bool(f.nameMatched),
                "hits": .array(f.lineHits.map {
                    .object([
                        "line": .int($0.lineNumber),
                        "offset": .int($0.utf16Offset),
                        "text": .string($0.lineText),
                    ])
                }),
            ])
        }),
    ]
    if let reason = run.emptyReason { o["emptyReason"] = .string(reason) }
    return .object(o)
}
