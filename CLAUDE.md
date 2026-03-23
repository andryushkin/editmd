# EditMD — Claude Guide

## Overview

Минималистичный Markdown редактор для macOS. AppKit (NSDocument) + SwiftUI Preview.
Два режима: Edit (NSTextView) / Preview (swift-markdown-ui).

## Project Structure

```
editmd/
├── docs/           # Планы и документация (plan-v2.md)
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

### NSTextStorage: комбинирование font traits (bold + italic)
При применении italic к тексту, который уже может быть bold — читать существующий шрифт из storage
и union трейты, иначе italic затрёт bold:
```swift
let existing = storage.attribute(.font, at: range.location, effectiveRange: nil)
    as? NSFont ?? fallbackFont
let combined = existing.fontDescriptor.symbolicTraits.union(.italic)
if let font = existing.withSymbolicTraits(combined) {
    storage.addAttribute(.font, value: font, range: range)
}
```

### NSDocument + package types: fileWrapper(ofType:) вызывается для ВСЕХ типов
При добавлении пакетного формата — `fileWrapper(ofType:)` вызывается для `.md` тоже!
Обязателен guard в начале:
```swift
override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
    guard typeName == "org.textbundle.package" else {
        return try super.fileWrapper(ofType: typeName)
    }
    // пакетная логика
}
```

### ImageProvider (MarkdownUI) + Swift 6: не использовать NSImage
`@MainActor struct` не может конформить nonisolated `ImageProvider` в Swift 6 strict mode.
Решение: `AsyncImage` с `file://` URL (резолвить путь до файла, отдать URL):
```swift
struct MyProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        AsyncImage(url: resolvedLocalURL(url)) { ... }
    }
}
```
`NSImage(contentsOf:)` — @MainActor в macOS 26 SDK, использовать нельзя.

### SourceKit false positives
При редактировании отдельных файлов SourceKit показывает "Cannot find type X" — это нормально,
пока проект не проиндексирован целиком. Проверяй реальные ошибки через `xcodebuild`.

### cmark C API: позиции узлов (1-based, UTF-8 байты)
`cmark_node_get_start_column` / `cmark_node_get_end_column` — **1-based UTF-8 byte column**.
Конвертация в UTF-16 NSRange требует маппинга байтов (см. `LineIndex` в `MarkdownEditorView.swift`).

Важные особенности по типам узлов:
- `CMARK_NODE_CODE` (inline code) — позиции span **только content** (без backticks). Расширять вручную: `sc - bt` / `offsetAfter(ec) + bt`, где `bt = cmark_node_get_backtick_count(node)`.
- `CMARK_NODE_STRONG`/`EMPH` — позиции включают маркеры (`**` / `*`); тело = весь nodeRange.
- `CMARK_NODE_HEADING` — позиции = вся строка заголовка включая `# `.
- `CMARK_NODE_LINK` — `cmark_node_first_child` / `cmark_node_last_child` дают диапазон текста внутри `[...]`.

### cmark: добавление как explicit SPM dep
`swift-cmark` — транзитивная зависимость `swift-markdown-ui`. Чтобы импортировать напрямую (`import cmark_gfm`), нужно добавить в `project.yml` явно:
```yaml
packages:
  swift-cmark:
    url: https://github.com/swiftlang/swift-cmark
    from: "0.7.1"
# и в target dependencies:
- package: swift-cmark
  product: cmark-gfm
```
SPM переиспользует уже скачанную версию из `Package.resolved` — без повторной загрузки.

## SPM Dependencies

- `swift-markdown-ui` (gonzalezreal) v2.4.1 — SwiftUI рендерер Markdown, тема `.gitHub`
  - Транзитивные: NetworkImage, cmark-gfm
- `swift-cmark` (swiftlang) v0.7.1 — cmark C библиотека, используется напрямую для AST-парсинга в редакторе

## Releases

### v1 — Initial
NSDocument + NSTextView + SwiftUI Preview. Два режима Edit/Preview.

### v2 — In Progress
- ✅ **Live Preview / cursor proximity** — маркеры (`#`, `**`, `*`, `>`, ссылки) скрыты везде кроме текущей строки. Паттерн: `rehighlight()`, `activeLine`, `isApplyingHighlight` (ренетранс-защита). Highlighting через cmark AST (`collectSpans` + `LineIndex`).
- ✅ **Настройки шрифта** — `EditorFontSettings` (singleton, UserDefaults), Format-меню ⌘=/⌘−
- ⬜ Счётчик слов/символов в статусбаре
- ⬜ Горячие клавиши форматирования (Cmd+B, Cmd+I)
- ✅ **Поддержка .textbundle** — `FileWrapper`-based read/write, `TextBundleImageProvider` (AsyncImage + file:// URL), UTI `org.textbundle.package` (конформирует `com.apple.package`)

Полный план: `docs/plan-v2.md`

## Conventions

- Планы и roadmap — сохранять в `docs/`
