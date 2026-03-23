# EditMD — Claude Guide

## Overview

Минималистичный Markdown редактор для macOS. AppKit (NSDocument) + SwiftUI Preview.
Два режима: Edit (NSTextView) / Preview (swift-markdown-ui).

## Project Structure

```
editmd/
├── research/
│   ├── MarkEdit/     # Референс: CodeMirror 6 + WKWebView архитектура
│   └── CodeEdit/     # Референс: TextKit 2 + CodeEditSourceEditor
└── EditMD/
    ├── project.yml   # xcodegen конфиг — ЕДИНСТВЕННЫЙ источник структуры проекта
    ├── EditMD.xcodeproj/
    └── EditMD/
        ├── App/        AppDelegate.swift, Info.plist
        ├── Document/   MarkdownDocument.swift
        ├── Editor/     EditorWindowController.swift, EditorViewController.swift
        └── Views/      MarkdownEditorView.swift, MarkdownPreviewView.swift, EditorFontSettings.swift
```

## Build

```bash
cd EditMD
xcodegen generate   # пересоздать .xcodeproj если менялся project.yml
xcodebuild -scheme EditMD -destination "platform=macOS" build
```

## Known Issues / Gotchas

### NSWindowController.document конфликт
Нельзя объявить `var document: MarkdownDocument` в подклассе NSWindowController —
конфликт с унаследованным `document: AnyObject?`. Используй `markdownDocument`.

### NSDocument.read() + Swift 6
`read(from:ofType:)` — nonisolated метод. Свойства, мутируемые в нём:
```swift
nonisolated(unsafe) var content: String = ""
```

### validateMenuItem — не override
`NSViewController` не объявляет `validateMenuItem`. Использовать:
```swift
extension MyViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { ... }
}
```

### NotificationCenter + @MainActor + Swift 6
Closure в `addObserver(forName:object:queue:using:)` — `@Sendable`, конфликт с `@MainActor`.
Решение: selector-based `addObserver(self, selector:, name:, object:)`.

### SourceKit false positives
При редактировании отдельных файлов SourceKit показывает "Cannot find type X" — это нормально,
пока проект не проиндексирован целиком. Проверяй реальные ошибки через `xcodebuild`.

## SPM Dependencies

- `swift-markdown-ui` (gonzalezreal) v2.4.1 — SwiftUI рендерер Markdown, тема `.gitHub`
  - Транзитивные: NetworkImage, cmark-gfm

## Next Steps (v2)

- ~~Live Preview: скрытие Markdown-символов при помощи NSTextLayoutManagerDelegate~~ ✅ (cursor proximity реализован)
- ~~Cursor proximity: показывать символы в текущем абзаце~~ ✅
- ~~Настройки шрифта через UserDefaults~~ ✅ (EditorFontSettings, Format-меню ⌘=/⌘−)
- Поддержка .textbundle (для изображений)
