---
tags: [editmd]
---

# EditMD

EditMD created this folder the first time it launched. Everything in it is an
ordinary Markdown file in an ordinary folder — move it, rename it, keep it in
Git, or delete the whole thing.

Your Markdown is the only source of truth. Around it the app may keep small
helper files you can delete at any time: a rebuildable link index in
`.editmd/` (self-ignoring, so Git never sees it), review marks in
`<file>.md.review.json` next to a reviewed document, and a `.smotr-queue.json`
when you hand a review to an agent.

## What is here

- **`Guide/`** — three short documents. Read them in the app, edit them while
  you read: they are yours now.
  - `Editing modes.md` — Source, Visual, Preview, Split and when each helps.
  - `Web clipper.md` — sending pages from the browser into this folder.
  - `Markdown showcase.md` — every element EditMD renders, in one file.
- **Your web clips** — notes sent from the browser are saved here as
  `Title.md`. A name that is already taken becomes `Title 2.md`; nothing is
  ever overwritten.

## First steps

1. Toggle the sidebar with **⌃⌘S** — this folder is already in it. Add any
   other folder with **File ▸ Open Folder…** (⇧⌘O).
2. Switch modes with **⌘1** Source, **⌘2** Visual, **⌘3** Preview, **⌘4**
   Split. It is one file and one text on disk; only the way you look at it
   changes.
3. Open [[Editing modes]] next.

## Sending pages from the browser

Install [HTML Text to .md — Online Markdown Web Clipper][ext] in Chrome, open
its side panel on any page and press **EditMD**: the captured Markdown lands
in this folder and opens in the editor — even if EditMD was not running.

Details, and what the `editmd://` links behind it can and cannot do, are in
[[Web clipper]].

## Where clips land

**Settings ▸ General ▸ Web clips** (⌘,) decides: keep this folder, pick a
different one, or follow whatever workspace is active in the sidebar.

## The project

Website: <https://dotmd.tools/editmd>

Source code, documentation and issues:
<https://github.com/andryushkin/editmd>

[ext]: https://chromewebstore.google.com/detail/gkplehkbkofmdjhafgbclcmfcficoego?utm_source=editmd
