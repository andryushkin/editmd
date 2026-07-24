---
tags: [editmd, guide]
---

# Web clipper

Keep the page you are reading as a Markdown note, in one click, without
leaving the browser.

## Setting it up

1. Install [HTML Text to .md — Online Markdown Web Clipper][ext] in Chrome.
2. Open its side panel on any page and capture the article (or a selection).
3. Press **EditMD**. The first time, Chrome asks whether to open EditMD —
   allow it.

The note appears in your clips folder and opens in the editor. EditMD does not
have to be running: macOS launches it for the handoff.

## Where the note goes

By default: the folder this guide lives in. **Settings ▸ General ▸ Web clips**
(⌘,) changes that — a fixed folder of your choice, or "Active workspace" to
follow whatever you have open in the sidebar.

The page title becomes the file name. If that name is taken, the next one is
used — `Article.md`, then `Article 2.md`, `Article 3.md`. An existing note is
never overwritten, renamed, or deleted.

## The link behind the button

The button opens a URL that any application can build:

```
editmd://new?file=Some%20Title&clipboard
```

- `file` — the name for the note, without an extension.
- `clipboard` — take the body from the system clipboard (that is how a whole
  article fits: URLs have a length limit).
- `workspace=<name>` — optional, puts the note in the workspace with that
  **name** from your sidebar. Unknown names are ignored and the note lands in
  the configured folder.

Everything else in such a URL is ignored. The command only ever creates a new
file: it cannot overwrite, move, or delete anything, cannot write outside the
destination folder, and the text it carries is saved verbatim, never executed.

## Also useful

- `pbpaste`-style automations: any script can call
  `open "editmd://new?file=Meeting%20notes&clipboard"`.
- Shortcuts.app: "Open URL" with the same address works as an action.

[ext]: https://chromewebstore.google.com/detail/gkplehkbkofmdjhafgbclcmfcficoego?utm_source=editmd
