# Vault: workspaces, links, lint, search

EditMD treats a folder of markdown files as a lightweight vault (in the
Obsidian sense): wiki-links resolve across the workspace, a link graph is
indexed and persisted, and lint reports vault-level problems.

## Workspaces and sidebar

The left sidebar (`Views/WorkspaceSidebar.swift`, `Views/WorkspaceModel.swift`)
shows adopted folders (workspaces) plus an "Open Files" section for files
opened outside any workspace. Folder analytics (subtree stats, empty/hidden
sections) are computed off-main and cached (`Views/FolderInfo.swift`).

## Wiki-links

`[[Target]]` and `[[Target|alias]]` syntax is recognized in all three modes.
Completion UI lives in `Editor/WikiCompletion*.swift`; resolution in
`Views/WikiLinkResolver.swift`. The parsing/graph core is deliberately
UI-free: `Editor/WikiLinkCore.swift`, `Editor/LinkGraphEngine.swift`,
`Editor/LinkScan.swift` — these files also compile into the `editmdctl`
target and must stay free of AppKit and app models (the list is in
`EditMD/project.yml`).

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
hand-rolled scalar fold covering ASCII and Cyrillic (including Ё) instead of
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
