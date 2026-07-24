---
title: Markdown showcase
tags: [editmd, guide, markdown]
---

# Markdown showcase

Everything below renders in all three modes. Edit it, break it, undo it —
this file is a scratchpad, not a reference you have to keep intact.

## Text

Plain paragraphs, **bold**, *italic*, ***both***, ~~struck out~~, `inline
code`, and a [link](https://github.com/andryushkin/editmd).

> A quote keeps its own indentation.
> — and a second line.

---

## Lists

- Bulleted item
- Another one
  - Nested one level
  - And a sibling

1. Numbered item
2. The next one
   1. Nested numbering

- [ ] A task that is still open
- [x] A task that is done

## Table

| Mode | Shortcut | Editable |
| --- | :---: | ---: |
| Source | ⌘1 | yes |
| Visual | ⌘2 | yes |
| Preview | ⌘3 | no |

## Code

```swift
struct Note {
    let title: String
    var body: String
}
```

```bash
open "editmd://new?file=From%20the%20shell&clipboard"
```

## Math

Inline: the area is $A = \pi r^2$.

Displayed:

$$
\int_{0}^{\infty} e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
$$

## Links between notes

`[[Editing modes]]` points at another file in this folder: [[Editing modes]].
Type `[[` anywhere to get the completion list.

## Images

Drag an image into the text and EditMD copies it next to the document:

![A picture that is not here yet](Images/example.png)

A missing file shows a placeholder instead of breaking the layout — the link
check (⌃⇧⌘L) lists it.

## Frontmatter

The block at the very top of this file is frontmatter: `title` and `tags`
belong to the document, and the Tags tab in the sidebar collects them. It
stays byte-for-byte as you wrote it, whichever mode you edit in.
