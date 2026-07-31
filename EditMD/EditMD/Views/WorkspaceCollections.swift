import Foundation

/// A named container for adopted roots in the Files sidebar — "Work",
/// "Personal", one per family of related projects. Presentation only: a
/// collection is never a search, link, tag or graph boundary, and it is never
/// an answer to `activeWorkspaceRoot`. Every index stays per root.
///
/// Membership lives on the root (`Workspace.collectionID`), not in a list of
/// member paths: the sidebar already rewrites `Workspace` values when a root is
/// renamed or removed, so the membership rides along for free and can never
/// point at a root that is no longer adopted.
struct WorkspaceCollection: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var collapsed: Bool = false

    init(id: String = UUID().uuidString, name: String, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
    }
}

/// One entry of the sidebar's top level: either a collection with its (ordered)
/// members, or a root that belongs to no collection.
enum SidebarTopLevelItem: Equatable, Identifiable {
    case collection(WorkspaceCollection, [WorkspaceModel.Workspace])
    case root(WorkspaceModel.Workspace)

    var id: String {
        switch self {
        case .collection(let collection, _): "c:" + collection.id
        case .root(let workspace): "r:" + workspace.folderPath
        }
    }
}

extension WorkspaceModel {

    // MARK: - Pure arrangement rules

    /// The order the sidebar renders, with every collection's members made
    /// contiguous. A collection sits where its first member sits, so putting a
    /// root into a collection never teleports the block to the end of the list.
    /// Memberships naming a collection that no longer exists decay to "no
    /// collection" — the root keeps its place instead of disappearing.
    nonisolated static func normalizedWorkspaces(
        _ workspaces: [Workspace],
        collections: [WorkspaceCollection]
    ) -> [Workspace] {
        let known = Set(collections.map(\.id))
        let cleaned = workspaces.map { workspace -> Workspace in
            guard let id = workspace.collectionID, !known.contains(id) else { return workspace }
            var workspace = workspace
            workspace.collectionID = nil
            return workspace
        }

        // Bucket once: this runs inside the sidebar's body, so it must stay
        // linear in roots rather than re-scanning the array per collection.
        var members: [String: [Workspace]] = [:]
        for workspace in cleaned {
            guard let id = workspace.collectionID else { continue }
            members[id, default: []].append(workspace)
        }

        var result: [Workspace] = []
        result.reserveCapacity(cleaned.count)
        var emitted = Set<String>()
        for workspace in cleaned {
            guard let id = workspace.collectionID else {
                result.append(workspace)
                continue
            }
            guard emitted.insert(id).inserted else { continue }
            result.append(contentsOf: members[id] ?? [])
        }
        return result
    }

    /// Collections nobody is in are dropped: an empty named container is a row
    /// that can only be deleted, never used. A repeated id is dropped with
    /// them — only the first one could ever be rendered, so a duplicate from
    /// hand-edited or merged defaults would persist as a row nobody can see,
    /// rename or collapse.
    nonisolated static func prunedCollections(
        _ collections: [WorkspaceCollection],
        workspaces: [Workspace]
    ) -> [WorkspaceCollection] {
        let used = Set(workspaces.compactMap(\.collectionID))
        var seen = Set<String>()
        return collections.filter { used.contains($0.id) && seen.insert($0.id).inserted }
    }

    /// Top level of the tree, over an already normalized array.
    nonisolated static func topLevelItems(
        workspaces: [Workspace],
        collections: [WorkspaceCollection]
    ) -> [SidebarTopLevelItem] {
        var byID: [String: WorkspaceCollection] = [:]
        for collection in collections where byID[collection.id] == nil {
            byID[collection.id] = collection
        }
        let normalized = normalizedWorkspaces(workspaces, collections: collections)
        // Members are contiguous after normalization, so one pass collects each
        // block — no per-collection re-scan of the array (this runs in `body`).
        var members: [String: [Workspace]] = [:]
        for workspace in normalized {
            guard let id = workspace.collectionID else { continue }
            members[id, default: []].append(workspace)
        }
        var items: [SidebarTopLevelItem] = []
        var emitted = Set<String>()
        for workspace in normalized {
            guard let id = workspace.collectionID, let collection = byID[id] else {
                items.append(.root(workspace))
                continue
            }
            guard emitted.insert(id).inserted else { continue }
            items.append(.collection(collection, members[id] ?? []))
        }
        return items
    }

    /// Moves one top-level item (a collection block, or an ungrouped root) past
    /// its neighbour. Whole blocks travel together, so a root can never end up
    /// wedged inside a collection it does not belong to.
    nonisolated static func movingTopLevelItem(
        id: String,
        by delta: Int,
        workspaces: [Workspace],
        collections: [WorkspaceCollection]
    ) -> [Workspace] {
        var items = topLevelItems(workspaces: workspaces, collections: collections)
        guard delta != 0, let from = items.firstIndex(where: { $0.id == id }) else {
            return normalizedWorkspaces(workspaces, collections: collections)
        }
        let to = from + delta
        guard items.indices.contains(to) else {
            return normalizedWorkspaces(workspaces, collections: collections)
        }
        items.swapAt(from, to)
        return items.flatMap { item -> [Workspace] in
            switch item {
            case .collection(_, let members): members
            case .root(let workspace): [workspace]
            }
        }
    }

    /// Moves a root inside its own collection. Members are contiguous after
    /// normalization, so the swap stays within the block by construction.
    nonisolated static func movingMember(
        path: String,
        by delta: Int,
        workspaces: [Workspace],
        collections: [WorkspaceCollection]
    ) -> [Workspace] {
        var normalized = normalizedWorkspaces(workspaces, collections: collections)
        guard delta != 0,
              let from = normalized.firstIndex(where: { $0.folderPath == path }),
              let collectionID = normalized[from].collectionID
        else { return normalized }
        let to = from + delta
        guard normalized.indices.contains(to),
              normalized[to].collectionID == collectionID
        else { return normalized }
        normalized.swapAt(from, to)
        return normalized
    }

    // MARK: - Reading

    /// What the Files tab renders at its top level.
    var sidebarTopLevelItems: [SidebarTopLevelItem] {
        Self.topLevelItems(workspaces: workspaces, collections: collections)
    }

    /// Roots the tree currently shows: everything except members of a collapsed
    /// collection. Selection order and the "which files are on screen" question
    /// both go through this.
    var visibleWorkspaces: [Workspace] {
        sidebarTopLevelItems.flatMap { item -> [Workspace] in
            switch item {
            case .collection(let collection, let members): collection.collapsed ? [] : members
            case .root(let workspace): [workspace]
            }
        }
    }

    func collection(withID id: String?) -> WorkspaceCollection? {
        guard let id else { return nil }
        return collections.first { $0.id == id }
    }

    /// The collection a root belongs to, `nil` when it stands on its own.
    func collection(of ws: Workspace) -> WorkspaceCollection? {
        collection(withID: workspaces.first { $0.id == ws.id }?.collectionID)
    }

    // MARK: - Mutating

    /// Creates a collection and puts `ws` in it (an empty collection would be
    /// pruned on the spot). Returns the collection so callers can chain.
    @discardableResult
    func createCollection(named rawName: String, with ws: Workspace) -> WorkspaceCollection? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, workspaces.contains(where: { $0.id == ws.id }) else { return nil }
        let collection = WorkspaceCollection(name: name)
        collections.append(collection)
        assign(ws, to: collection)
        return collections.first { $0.id == collection.id }
    }

    /// Puts a root into a collection (or takes it out with `nil`).
    func assign(_ ws: Workspace, to collection: WorkspaceCollection?) {
        guard let index = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        workspaces[index].collectionID = collection?.id
        rearrange()
    }

    func renameCollection(_ collection: WorkspaceCollection, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = collections.firstIndex(where: { $0.id == collection.id })
        else { return }
        collections[index].name = name
    }

    func toggleCollapsed(_ collection: WorkspaceCollection) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[index].collapsed.toggle()
    }

    func expandCollection(_ collection: WorkspaceCollection) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }),
              collections[index].collapsed
        else { return }
        collections[index].collapsed = false
    }

    /// Dissolves a collection: its roots stay adopted, in the same order, and
    /// become top-level rows again.
    func dissolveCollection(_ collection: WorkspaceCollection) {
        for index in workspaces.indices where workspaces[index].collectionID == collection.id {
            workspaces[index].collectionID = nil
        }
        rearrange()
    }

    func moveWorkspace(_ ws: Workspace, by delta: Int) {
        guard let current = workspaces.first(where: { $0.id == ws.id }) else { return }
        applyArrangement(current.collectionID == nil
            ? Self.movingTopLevelItem(id: "r:" + current.folderPath, by: delta,
                                      workspaces: workspaces, collections: collections)
            : Self.movingMember(path: current.folderPath, by: delta,
                                workspaces: workspaces, collections: collections))
    }

    func moveCollection(_ collection: WorkspaceCollection, by delta: Int) {
        applyArrangement(Self.movingTopLevelItem(
            id: "c:" + collection.id, by: delta,
            workspaces: workspaces, collections: collections))
    }

    /// Re-applies contiguity and drops collections left empty. Called after
    /// every membership change and after a root leaves the sidebar.
    func rearrange() {
        let pruned = Self.prunedCollections(collections, workspaces: workspaces)
        if pruned != collections { collections = pruned }
        applyArrangement(Self.normalizedWorkspaces(workspaces, collections: collections))
    }

    /// Installs a new arrangement. With no document open, `activeWorkspaceRoot`
    /// falls back to the first root — the branch a fresh launch opens — so a
    /// reorder can move the vault the link graph answers for. The arrangement
    /// stays presentation, but the index must not keep answering for the root
    /// that used to be first: re-key it (a no-op unless someone built it).
    private func applyArrangement(_ arranged: [Workspace], index: LinkIndex = .shared) {
        guard arranged != workspaces else { return }
        let rootBefore = activeWorkspaceRoot
        workspaces = arranged
        guard activeWorkspaceRoot != rootBefore else { return }
        index.noteActiveDocumentChanged(workspace: self)
    }
}
