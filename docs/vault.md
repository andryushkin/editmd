# Vault: workspaces, links, lint, search

EditMD treats a folder of markdown files as a lightweight vault (in the
Obsidian sense): wiki-links resolve across the workspace, a link graph is
indexed and persisted, and lint reports vault-level problems.

## Workspaces and sidebar

The left sidebar (`Views/WorkspaceSidebar.swift`, `Views/WorkspaceModel.swift`)
shows adopted folders (workspaces) plus an "Open Files" section for files
opened outside any workspace. Folder analytics (subtree stats, empty/hidden
sections) are computed off-main and cached (`Views/FolderInfo.swift`).

Subfolders with no document anywhere in their tree (`emptySubfolders`) are
treated like hidden files: grouped behind the eye toggle in the tree, and in a
dimmed "Empty Folders" section in the folder card. The exception is folders the
user creates in-app (New Folder): `createSubfolder` records them in
`keptFolders` (persisted, per workspace, relative paths — mirrors `hiddenFiles`)
so a brand-new empty folder stays visible instead of vanishing the moment it is
made. `isKeptOrHoldsKept` decides visibility: a folder shows when it is kept
itself **or** is an empty ancestor of a kept folder (`containsKeptFolder`) —
otherwise a kept folder made inside a found-on-disk empty parent would be
unreachable, hidden along with the parent. `keptFolders` is keyed by workspace
root, so `migrateRootState` relocates its keys on a disk rename alongside
`hiddenFiles`. A stale entry for a *directly* kept folder is harmless
(`keptEmptySubfolders` intersects the set with folders that still exist), but a
stale entry would keep an ancestor visible forever through `containsKeptFolder`,
so `pruneStaleKeptFolders` drops entries whose folder is gone — called from
`forgetTrashedFolder` (in-app trash) and on activation (external deletes). The
existence probe runs on a detached task and applies on the main actor behind an
unchanged-snapshot guard (mirroring `refreshFavoriteAvailability`), so a network
or offline workspace volume never stalls the UI.

### File and folder operations

Context menus create (New File / New Folder), move, rename and trash items.
The disk cores are pure statics in `Views/WorkspaceModelDiskMoves.swift`; the
UI transactions live in `Views/FileMoveActions.swift`:

- **Move** (`performFileMoves`, drag or menu) and **Rename**
  (`performFileRename`, same folder, new basename) are transactional: an open
  document is parked (`DocumentRegistry` preparation) before the disk write and
  restored at the new path, so autosave and the file watcher stay coherent. A
  review sidecar (`.review.json`) always follows its document; a mid-batch disk
  failure rolls back before the error surfaces, and both paths share the same
  survivor-probing recovery (`fileMoveRecoveryResolutions`) when a rollback
  itself fails; survivor probes compare the actual directory-entry spelling
  (`directoryEntryExists`), so case-only outcomes classify correctly. Rename preserves the original extension when the new name
  omits one, and case-only renames go through a temporary sibling
  (`moveFileForRename`) because a case-insensitive volume reports the new
  spelling as an existing item; an exact-spelling destination entry is a
  genuine collision even when it shares the source's file identity
  (hardlinked case-variant names on a case-sensitive volume). Dot-prefixed names are refused everywhere
  (`FolderNaming`) — listings skip hidden files, so the item would vanish.
- **Move to Trash** works on files (`confirmAndMoveFilesToTrash`) and whole
  folders (`confirmAndMoveFolderToTrash`). A folder is refused while any open
  document lives inside it — matching disk-rename — and the guard re-runs
  after the confirmation modal (the run loop drains main-actor work while the
  dialog is up). The confirm warns when recently closed documents under the
  root still hold unsaved buffers (`DocumentRegistry.hasUnsavedChanges`).
  `trashItem` runs detached under `LongRunningOperationCenter`; cleanup then
  drops registry caches (`discardFolderCaches`), navigation and history state
  (`AppState.discardPathState`), change-tracking baselines
  (`LineChangeTracker.forget(under:)`), and sidebar state
  (`forgetTrashedFolder` — adopted roots, favorites, pins, expansion).

Disk mutations go through `WorkspaceModel`, which bumps `contentEpoch` /
`linkEpoch` (`noteFilesystemChange`) to invalidate caches and the link index.

## Wiki-links

`[[Target]]` and `[[Target|alias]]` syntax is recognized in all three modes.
Completion UI lives in `Editor/WikiCompletion*.swift`; resolution in
`Views/WikiLinkResolver.swift`. The parsing/graph core is deliberately
UI-free: `Editor/WikiLinkCore.swift`, `Editor/LinkGraphEngine.swift`,
`Editor/LinkScan.swift` — these files also compile into the `editmdctl`
target and must stay free of AppKit and app models (the list is in
`EditMD/project.yml`).

## Scheme completion in the ⌘K dialog

A destination typed without a scheme is stored as authored only when it reads
as local; a bare host gets `https://`, an address `mailto:`, a
port-carrying server `http://` (`Editor/LinkEdit.swift`). Three rules keep this
from mangling a vault:

- Completion needs a TLD from a curated list, and the list deliberately omits
  the codes that double as extensions a vault or repo is full of (`md`, `sh`,
  `cc`, `am`, `in`, `pro`). By shape alone `example.com` is indistinguishable
  from `build.sh` or a PARA folder like `2.Areas/note.md`, and a rare TLD left
  for the author to type beats a working relative link rewritten into an
  unreachable URL.
- The file system settles what shape cannot. `LocalDestinationCache` resolves
  what is typed **in the background as the user types** and OK only reads the
  answer — it never waits and never stats: the main actor does not block on a
  volume (§ Performance in `architecture.md`), and one slow enough to still be
  thinking would not have been saved by a timeout. Resolution is
  `resolveLocalLinkDestination` with the same roots as the link opener and vault
  lint — the adopted workspace, else the nearest `.obsidian` above the file —
  with one deliberate narrowing: lint also accepts a wiki-index basename match
  for a markdown link, which the dialog does not consult, so a destination
  resolving *only* by basename counts as missing here.
- A destination ending in a file the app opens is **never** completed, and the
  probe is not consulted for it: whether the note exists *yet* cannot decide the
  everyday forward link (write the link, create `plan.md` after), and asking
  would make the stored destination depend on whether the answer had arrived.
  Everything else completes by shape, and the probe can only ever *save* a local
  file from that — a hit on `Makefile.am` or on a folder named `docs.io` keeps
  the path. That half is best-effort by nature: a probe still in flight leaves
  the shape rule in charge, exactly as a "missing" answer would, so the two
  cannot diverge.

A plain `notes.md` stays local whatever the answer: `md` is not a completable
TLD, so linking a note before creating it keeps working.

## Link index

`Views/LinkIndex.swift` maintains the in-memory graph: outgoing links,
backlinks, and tag occurrences per file, refreshed by a file watcher.
`Editor/LinkIndexPersistence.swift` writes the on-disk form to
`<workspace>/.editmd/link-index.json`:

- Workspace-only — loose/lite documents never create `.editmd/`.
- All paths are relative to the workspace root, so the vault stays portable.
- `.editmd/.gitignore` (`*`) makes the directory self-ignoring — the index is
  a cache.
- Output is deterministic (sorted files and keys): repeated saves of an
  unchanged vault are byte-identical, which external tools rely on.
- A corrupt or foreign-version file is silently ignored and overwritten by
  the next successful scan.

Loading is defensive, because the file is a cache that external tools may
have touched:

- Every path read from the file must be **relative and free of `..`
  components** (`isSafeRelativePath`); cache entries are re-keyed to absolute
  standardized URLs on load.
- A single unsafe resolved/candidate path taints the *entire* resolve info of
  its entry — the file degrades to a plain rescan for that entry rather than
  trusting a partially valid record.
- Cached link resolution is reused only while its `resolveFingerprint`
  matches — the fingerprint covers **all** paths that could affect
  resolution, so a rename anywhere in the vault invalidates dependent
  entries instead of serving stale targets.

External tools (the offline engine in `editmdctl`, wikillm-style agents) read
the same file — see [integration.md](integration.md).

## Vault lint

`Editor/VaultLint.swift` reports dead links, orphans (no backlinks), and
self-link cases across the workspace; results feed the lint report view
(`Views/VaultLintReportView.swift`) and the `lint` control command. A file
whose only link points to itself counts as both an orphan and `selfWikiLink`.

## Search

Workspace search (`Views/WorkspaceSearchModel.swift`, `Editor/SearchQuery.swift`,
`Editor/SearchMatch.swift`) supports tokens, quoted phrases, and filters
(`path:`, `type:`, `tag:`, `is:modified`, `after:`). Matching uses a
hand-rolled scalar fold covering ASCII and Cyrillic (including Yo, U+0401)
instead of
Foundation case-insensitive search — the fold table is the invariant to extend
when broader coverage is needed, not a switch to Foundation (performance).

## Tags and frontmatter

`Editor/TagScan.swift` extracts `#tags`; the Tags sidebar groups occurrences.
Frontmatter is parsed by `Editor/Frontmatter.swift` and edited through the
"Properties" panel (`Views/PropertiesPanel.swift`) as a form; edits go through
`Editor/FrontmatterEdit.swift` and the normal undo path. Built-in plugins
(`Editor/BuiltInPlugins.swift`) activate per document via frontmatter and may
edit only registry-whitelisted fields (`updateConfiguration`) — never
arbitrary YAML paths or text ranges.
