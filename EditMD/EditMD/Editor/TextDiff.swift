import Foundation

// MARK: - Line diff (GitHub-style unified)

enum DiffLineKind: Equatable, Sendable {
    case same
    case insert
    case delete
}

struct DiffLine: Equatable, Sendable {
    let kind: DiffLineKind
    let text: String
    /// 1-based line number in the "before" side (nil for pure inserts).
    let oldNumber: Int?
    /// 1-based line number in the "after" side (nil for pure deletes).
    let newNumber: Int?
}

struct LineDiffResult: Equatable, Sendable {
    let lines: [DiffLine]
    let added: Int
    let removed: Int

    var isEmpty: Bool { added == 0 && removed == 0 }
}

/// Splits on `\n` keeping empty trailing segments so `"a\n"` ≠ `"a"`.
func splitDiffLines(_ text: String) -> [String] {
    if text.isEmpty { return [""] }
    // `split` on a trailing newline yields a final empty string — keep it so
    // "file ends with newline" is visible in the diff.
    return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

/// Line-oriented Myers diff via `CollectionDifference`. Fine for notes;
/// callers should cap display when `lines.count` is huge.
func lineDiff(before: String, after: String) -> LineDiffResult {
    let oldL = splitDiffLines(before)
    let newL = splitDiffLines(after)
    if oldL == newL {
        return LineDiffResult(lines: oldL.enumerated().map { i, t in
            DiffLine(kind: .same, text: t, oldNumber: i + 1, newNumber: i + 1)
        }, added: 0, removed: 0)
    }

    // Hard cap: O(n) walk is fine, but building 100k row views is not.
    // Still compute a coarse summary when either side is enormous.
    if oldL.count + newL.count > 30_000 {
        return LineDiffResult(
            lines: [
                DiffLine(kind: .delete, text: "… \(oldL.count) lines (before)",
                         oldNumber: 1, newNumber: nil),
                DiffLine(kind: .insert, text: "… \(newL.count) lines (after)",
                         oldNumber: nil, newNumber: 1),
            ],
            added: newL.count,
            removed: oldL.count
        )
    }

    let diff = newL.difference(from: oldL)
    var removals: [(Int, String)] = []
    var insertions: [(Int, String)] = []
    for change in diff {
        switch change {
        case let .remove(offset, element, _):
            removals.append((offset, element))
        case let .insert(offset, element, _):
            insertions.append((offset, element))
        }
    }
    removals.sort { $0.0 < $1.0 }
    insertions.sort { $0.0 < $1.0 }

    var result: [DiffLine] = []
    result.reserveCapacity(oldL.count + insertions.count)
    var ri = 0, ii = 0
    var o = 0, n = 0
    var added = 0, removed = 0

    while o < oldL.count || n < newL.count {
        let isRem = ri < removals.count && removals[ri].0 == o
        let isIns = ii < insertions.count && insertions[ii].0 == n
        if isRem {
            result.append(DiffLine(kind: .delete, text: removals[ri].1,
                                   oldNumber: o + 1, newNumber: nil))
            removed += 1
            ri += 1
            o += 1
        } else if isIns {
            result.append(DiffLine(kind: .insert, text: insertions[ii].1,
                                   oldNumber: nil, newNumber: n + 1))
            added += 1
            ii += 1
            n += 1
        } else if o < oldL.count, n < newL.count {
            result.append(DiffLine(kind: .same, text: oldL[o],
                                   oldNumber: o + 1, newNumber: n + 1))
            o += 1
            n += 1
        } else if o < oldL.count {
            result.append(DiffLine(kind: .delete, text: oldL[o],
                                   oldNumber: o + 1, newNumber: nil))
            removed += 1
            o += 1
        } else {
            result.append(DiffLine(kind: .insert, text: newL[n],
                                   oldNumber: nil, newNumber: n + 1))
            added += 1
            n += 1
        }
    }

    return LineDiffResult(lines: result, added: added, removed: removed)
}
