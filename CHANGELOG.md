# Changelog

User-facing changes, newest first. The version scheme and release process are
described in [docs/releasing.md](docs/releasing.md).

## v0.48.0 - 2026-08-29

### New Features

- A file opened from outside any folder can hand you its own folder: the
  Open Files row offers to adopt it as a workspace, and the usual folder
  chooser opens there. It opens there rather than adopting it outright
  because the folder a file sits in is often a leaf, and the one worth
  opening is a level or two above it — now you start at the path you were
  already looking at instead of walking back to it.

### Bug Fixes

- Adopting a folder above the file finally takes the file out of Open Files.
  The row only left when the chosen folder was the file's own, so the case
  the chooser exists for left the file listed twice — once loose, once in the
  tree. A pinned row never left at all, and came back after a relaunch.

## v0.47.16 - 2026-08-02

### Improvements

- The sidebar marks the branch the open document is in: every folder above it
  is filled, and the folder holding it is accented — the adopted folder and the
  collection that own it included, so a collapsed collection still says the
  document is somewhere inside. A filled folder used to mean "expanded", which
  left a lit trail behind every branch you had walked through.
- Collections and adopted folders have glyphs of their own, so a collection no
  longer reads as one more folder among the folders it contains.

### Bug Fixes

- A folder dragged into a collection takes its contents with it. The header
  moved to the collection's column while everything below it stayed on the old
  one, and only a relaunch straightened the tree out.

## v0.47.15 - 2026-08-01

### New Features

- EditMD now says when a newer version has been released. It asks
  dotmd.tools once a day and speaks only when there is something newer — the
  app still never updates itself. A copy installed with Homebrew is handed
  the `brew upgrade` command; everyone else is offered the download page. A
  release this Mac is too old to run is explained rather than passed over in
  silence.
- Check for Updates… in the EditMD menu asks on the spot and always answers,
  including "you are up to date". The daily check can be switched off in
  Settings ▸ General; the request carries the version and the macOS it comes
  from, and nothing that identifies you.

## v0.47.14 - 2026-08-01

### New Features

- Folders in the Files sidebar can be grouped into named collections — Work,
  Personal, one per family of projects. A collection can be renamed, moved, and
  collapsed as a unit, hiding all of its folders at once, and the arrangement
  survives a relaunch. Drag one folder onto another to make a collection, or
  onto a collection to join it; the same commands live in the folder's context
  menu. Grouping is presentation only: search, tags, wiki-links and the link
  index keep working per folder exactly as before.

### Bug Fixes

- Scrolling with the pointer near a pane divider works again — the invisible
  grab strip along the divider used to swallow the wheel.
- Clicking a sidebar row close to a divider no longer nudges the pane: only an
  actual drag resizes it, and a drag started from the edge of the divider's
  grab area now follows the pointer instead of jumping.
- The resize cursor no longer stays behind over the Preview after leaving a
  divider.
- ⌘-hovering a link that runs off the top or bottom of the window underlines
  the whole link, not just its visible half.

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
