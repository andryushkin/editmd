# Changelog

User-facing changes, newest first. The version scheme and release process are
described in [docs/releasing.md](docs/releasing.md).

## v0.47.11 - 2026-07-24

### New Features

- Rename files in place from the sidebar and the folder card ("Rename…").
  The extension is kept when the new name omits one, review marks follow the
  file, and case-only renames (note.md → Note.md) work on the default macOS
  file system.
- Move whole folders to the Trash from the folder context menu. Refused while
  documents inside are open; warns when recently closed files still hold
  unsaved changes.

### Improvements

- Names starting with a dot are refused when creating or renaming files and
  folders — such items are hidden and would silently disappear from the list.

## v0.47.10 - 2026-07-23

Initial public release.

EditMD is a native macOS Markdown editor: Source / Visual / Preview modes over
one markdown source of truth; workspace sidebar with files, outline, git
status, review marks, and tags; wiki-links with a persistent link index and
vault lint; KaTeX math, highlighted code, tables, images, PDF export;
English/Russian UI; and Claude Code integration — the app works as an IDE over
MCP, and `editmdctl` answers vault-graph queries from the command line.
Development history before this point is not covered here.
