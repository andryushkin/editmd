import Foundation

/// One spelling of "is this path inside that root", and the relative path that
/// follows from it.
///
/// The comparison is by **text**, the way Foundation does it — not by whole
/// components. Three corners follow, and the hand-written form
/// `p == r || p.hasPrefix(r + "/")` got two of them wrong:
///
/// - a root of `/` — `r + "/"` asks for a prefix `//`, which matches nothing,
///   so a root adopted at `/` used to own no file at all;
/// - a root spelled with a trailing slash — the same failure one level down;
/// - a sibling whose name merely starts with the root's (`/vaultx` under
///   `/vault`) is **not** inside it. That one the hand-written form got right,
///   and repairing the first two must not lose it.
///
/// # A site does not use this if its answer is recorded
///
/// Some path comparisons are contracts with something outside this process:
/// their answer enters a fingerprint, the on-disk index, or a wire format, and
/// changing the spelling moves a recorded number. Those change only in pairs,
/// with the other side, and they keep their own copy on purpose. Prefer this
/// rule to a list of exceptions — a list goes stale the moment someone writes
/// the next copy, a rule tells them which kind they have.
///
/// The one in the tree today is `LinkGraphEngine.relativePath(_:roots:)`; its
/// comment names the other half of that contract.
///
/// Comparing whole components instead — which is what the vault core does on
/// the other side of the language boundary — is a related but different
/// function, and deliberately not what this is.
enum PathScope {

    /// `path` relative to `root`: `""` when they are the same path, `nil` when
    /// `path` is not inside `root`.
    ///
    /// A caller that must reject the root itself checks for the empty result —
    /// several do, because they go on to build an index key or a hide entry
    /// that an empty string would corrupt.
    static func relative(_ path: String, under root: String) -> Substring? {
        let base = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        if path == base || path == root { return "" }
        let prefix = base == "/" ? "/" : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return path.dropFirst(prefix.count)
    }

    /// True when `path` is `root` or lies under it.
    static func contains(_ path: String, under root: String) -> Bool {
        relative(path, under: root) != nil
    }

    /// True when `path` lies **strictly** under `root` — the root itself is
    /// not inside. What a caller wants when the answer becomes an index key or
    /// a relative path: the root relativizes to nothing, and nothing is not a
    /// key. Several sites reject the empty result for exactly that reason.
    static func containsStrictly(_ path: String, under root: String) -> Bool {
        guard let rest = relative(path, under: root) else { return false }
        return !rest.isEmpty
    }
}
