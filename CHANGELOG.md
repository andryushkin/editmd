# Changelog

User-facing changes, newest first. The version scheme and release process are
described in [docs/releasing.md](docs/releasing.md).

## v0.47.13 - 2026-07-26

### New Features

- A web page can hand a note to EditMD through the `editmd://` URL scheme, so a
  browser clipper can save straight into a vault. The clip becomes a new file —
  the name is re-sanitized and made unique, and an existing file is never
  overwritten. Settings ▸ General ▸ Web clips chooses where clips land: a fixed
  folder or the active workspace.
- A new installation starts with `~/Documents/EditMD` instead of an empty
  window: a README and a `Guide/` covering the editing modes, the web clipper,
  and a showcase of every Markdown element the editor renders. Seeding never
  overwrites, and a folder you delete does not come back.
- The ⌘K link dialog completes a destination typed without a scheme:
  `example.com` becomes `https://example.com`, an e-mail address becomes a
  `mailto:` link, and `localhost:8080` or a bare IP address becomes `http://`.
  Anything that belongs to the vault is left exactly as typed — including a
  note you have not created yet, such as `plan.md`, and paths whose extension
  doubles as a country code (`build.sh`, `Makefile.am`).

### Improvements

- Text fields in the app's own dialogs — the link editor, the file and folder
  name prompts — take keyboard focus the moment the dialog opens, and are drawn
  as fields instead of flat captions.
- Confirming the ⌘K dialog without editing the label keeps the label exactly as
  written: `[**bold**](example.com)` no longer flattens to `[bold](…)`, and
  Remove Link puts back the original text with its escapes intact.
- A name pasted into a file or folder prompt no longer carries line breaks or
  control characters into the file system.
- Empty folders you create stay visible in the sidebar.
- The system's own permission prompts (access to Documents) now appear in
  Russian when the app runs in Russian.

### Bug Fixes

- ⌘X / ⌘C / ⌘V / ⌘A did nothing inside the app's own dialogs. The stock Edit
  menu items are back, so the clipboard works in the link editor and the name
  prompts again.

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
