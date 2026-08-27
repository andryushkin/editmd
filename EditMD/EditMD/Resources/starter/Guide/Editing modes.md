---
tags: [editmd, guide]
---

# Editing modes

One file, one text on disk, four ways to look at it. Switch any time — the
Markdown never changes behind your back.

| Mode | Shortcut | What it is for |
| --- | --- | --- |
| **Source** | ⌘1 | The raw Markdown, with syntax colouring and linting. Where you fix a stubborn table or a link by hand. |
| **Visual** | ⌘2 | Formatted text you type into directly: headings look like headings, `**bold**` looks bold. Writing mode. |
| **Preview** | ⌘3 | The finished page: formatted text, images and maths, read-only. Reading mode. |
| **Split** | ⌘4 | Source on the left, Preview on the right, scrolling together. |

## Writing in Visual

Formatting works the way it does in any editor:

- **⌘B** bold, **⌘I** italic, **⇧⌘X** strikethrough, **⇧⌘C** code span
- **⌥⌘1 … ⌥⌘6** heading levels, **⌘L** bulleted list, **⌥⌘L** numbered,
  **⇧⌘L** checklist
- **⇧⌘U** quote, **⌥⌘C** code block, **⌘K** link

Paste a URL over selected text and it becomes a link. Drag an image into the
text and it is copied next to the document and inserted.

## Finding your way

- **⌃⌘S** — the left sidebar: Files, Outline, Git, Review, Tags.
- **⌥⌘0** — the right inspector: everything about the current document.
- **⌘F** — find (in Preview too), **⌥⌘F** — find and replace.
- **⌘[** and **⌘]** — back and forward through the documents you visited.
- **⇧⌘E** — export the current document as PDF.

## Linking notes together

`[[Wiki links]]` point at other files in the same workspace by name — start
typing `[[` and the completion list appears. **View ▸ Check Workspace Links**
(⌃⇧⌘L) reports the ones that resolve to nothing.

Tags live in the frontmatter block at the top of a file, like the one in this
document; the sidebar's Tags tab collects them.

## Next

- [[Web clipper]] — pull pages from the browser into your notes.
- [[Markdown showcase]] — one file with every element the editor renders.
