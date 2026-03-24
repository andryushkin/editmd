# EditMD — Claude Guide

## Overview

Минималистичный Markdown редактор для macOS. Чистый SwiftUI App lifecycle + `DocumentGroup` + `ReferenceFileDocument`.
NSTextView обёрнут в `NSViewRepresentable` для подсветки синтаксиса.
Два режима: Edit (NSTextView) / Preview (swift-markdown-ui).
Меню — через SwiftUI `.commands` + `@FocusedValue` в `EditMDApp.swift`.

## Project Structure

```
editmd/
└── EditMD/
    ├── project.yml   # xcodegen конфиг — ЕДИНСТВЕННЫЙ источник структуры проекта
    ├── EditMD.xcodeproj/
    └── EditMD/
        ├── App/        EditMDApp.swift (entry point, DocumentGroup, SwiftUI commands), Info.plist
        ├── Document/   MarkdownDocument.swift (ReferenceFileDocument)
        ├── Editor/     MarkdownTextView.swift (NSViewRepresentable), MarkdownHighlighter.swift, FormattingHelpers.swift
        └── Views/      ContentView.swift, MarkdownPreviewView.swift, EditorFontSettings.swift, FocusedValues.swift
    EditMDTests/
        ├── MarkdownHighlighterTests.swift   # 59 XCTest кейсов для LineIndex + collectSpans (все markdown-элементы)
        ├── FormattingHelpersTests.swift     # 14 XCTest кейсов для wordAndCharCount + applyWrap
        └── EditMenuTests.swift             # 7 XCTest кейсов для MarkdownDocument
```

## Build

```bash
cd EditMD
xcodegen generate   # пересоздать .xcodeproj если менялся project.yml
xcodebuild -scheme EditMD -destination "platform=macOS" build
xcodebuild -scheme EditMD -destination "platform=macOS" -enableCodeCoverage NO test  # запуск тестов
```

> **Note:** `-enableCodeCoverage NO` обязателен — без него linker error `___llvm_profile_runtime`.

## Architecture

### DocumentGroup + ReferenceFileDocument
`EditMDApp.swift` использует `DocumentGroup(newDocument:editor:)`. Документ — `MarkdownDocument` (class, `ReferenceFileDocument`).
DocumentGroup автоматически предоставляет File меню (New/Open/Save/Save As/Revert) — ручные File-команды не нужны.

### NSTextView через NSViewRepresentable
`MarkdownTextView.swift` — обёртка NSTextView. Coordinator содержит:
- NSTextViewDelegate (textDidChange, textViewDidChangeSelection)
- Подсветка синтаксиса (applyHighlighting, rehighlight)
- Форматирование (toggleBold, toggleItalic, wrapSelection)
- Счётчик слов/символов
- Обработка изменения шрифта

### @FocusedValue для меню Format
Кастомные команды (Bold/Italic/Font size) передаются через `@FocusedValue(\.formatActions)`.
Стандартные команды (Cut/Copy/Paste/Undo/Redo) — через `NSApp.sendAction` → responder chain.

### Feedback loop prevention
В `updateNSView` флаг `isInternalUpdate` предотвращает цикл:
textDidChange → document.content = ... → SwiftUI вызывает updateNSView → НЕ перезаписываем textView.string.

## Known Issues / Gotchas

### ReferenceFileDocument.init(configuration:) — nonisolated
Protocol methods `init(configuration:)`, `snapshot()`, `fileWrapper()` — nonisolated.
Свойства, мутируемые в них:
```swift
nonisolated(unsafe) var content: String
nonisolated(unsafe) var assetsFileWrapper: FileWrapper?
```

### Snapshot + FileWrapper Sendable
`FileWrapper` не конформит `Sendable`. Snapshot маркирован `@unchecked Sendable`:
```swift
struct Snapshot: @unchecked Sendable {
    let content: String
    let assetsFileWrapper: FileWrapper?
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

### ImageProvider (MarkdownUI) + Swift 6: не использовать NSImage
`@MainActor struct` не может конформить nonisolated `ImageProvider` в Swift 6 strict mode.
Решение: `AsyncImage` с `file://` URL (резолвить путь до файла, отдать URL).
`NSImage(contentsOf:)` — @MainActor в macOS 26 SDK, использовать нельзя.

### NSTextBlock не работает при isRichText = false
`NSTextBlock` (border, padding через `NSMutableParagraphStyle.textBlocks`) — не рендерится когда `NSTextView.isRichText = false`.
Для рисования левых полос/фона блоков использовать подкласс NSTextView с переопределением `drawBackground(in:)`:
```swift
class MarkdownNSTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // использовать layoutManager.enumerateLineFragments для позиций строк
    }
}
```

### quoteMarker в вложенных blockquote
`cmark_node_get_start_column(node)` даёт колонку `>` для данного уровня вложенности (sc=1 для внешнего, sc=3 для вложенного после `> `).
Для поиска маркера на каждой строке: `lineIdx.offset(line, sc)`, НЕ `lineIdx.lineStart(line)`.

### Меню: Undo/Redo selectors
Для Undo/Redo — `Selector(("undo:"))` / `Selector(("redo:"))` (с двоеточием),
потому что `#selector(UndoManager.undo)` даёт `undo` без `:`, а AppKit ожидает `undo:`.

### SourceKit false positives
При редактировании отдельных файлов SourceKit показывает "Cannot find type X" — это нормально,
пока проект не проиндексирован целиком. Проверяй реальные ошибки через `xcodebuild`.

### xcodebuild test: linker error ___llvm_profile_runtime
Unit-test bundle без host app не линкует code coverage runtime. Всегда передавать:
`-enableCodeCoverage NO` при вызове `xcodebuild test`.

### cmark C API: позиции узлов (1-based, UTF-8 байты)
`cmark_node_get_start_column` / `cmark_node_get_end_column` — **1-based UTF-8 byte column**.
Конвертация в UTF-16 NSRange требует маппинга байтов (см. `LineIndex` в `MarkdownHighlighter.swift`).

Важные особенности по типам узлов:
- `CMARK_NODE_CODE` (inline code) — позиции span **только content** (без backticks). Расширять вручную: `sc - bt` / `offsetAfter(ec) + bt`, где `bt = cmark_node_get_backtick_count(node)`.
- `CMARK_NODE_STRONG`/`EMPH` — позиции включают маркеры (`**` / `*`); тело = весь nodeRange.
- `CMARK_NODE_HEADING` — позиции = вся строка заголовка включая `# `; trailing `\n` НЕ включается в `ec`.
- `CMARK_NODE_LINK` — `cmark_node_first_child` / `cmark_node_last_child` дают диапазон текста внутри `[...]`.
- `CMARK_NODE_CODE_BLOCK` — fenced: `cmark_node_get_fence_info != nil`; indented: fence_info == nil. Позиции включают fence строки.
- `CMARK_NODE_ITEM` — позиции начинаются с маркера (`-`, `*`, `1.`). Длину маркера определяем сканированием текста.
- `CMARK_NODE_IMAGE` — аналогичен LINK: `![` + alt text + `](url)`.

### cmark GFM extensions: extern node types недоступны из Swift
`CMARK_NODE_STRIKETHROUGH`, `CMARK_NODE_TABLE` и пр. — extern переменные из внутренних заголовков (`strikethrough.h`, `table.h`), которые НЕ экспортируются через `module.modulemap` пакета `cmark-gfm-extensions`. Сравнение через `cmark_node_get_type_string(node)`:
```swift
let typeStr = cmark_node_get_type_string(node).flatMap { String(cString: $0) }
// typeStr == "strikethrough", "table", "table_row", "table_cell"
```

### cmark GFM parser API
Для поддержки GFM-расширений (strikethrough, table, tasklist, autolink) необходимо использовать явный parser API вместо `cmark_parse_document()`:
```swift
import cmark_gfm_extensions
cmark_gfm_core_extensions_ensure_registered()
let parser = cmark_parser_new(CMARK_OPT_DEFAULT)
for name in ["strikethrough", "table", "tasklist", "autolink"] {
    if let ext = cmark_find_syntax_extension(name) {
        cmark_parser_attach_syntax_extension(parser, ext)
    }
}
```

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
- package: swift-cmark
  product: cmark-gfm-extensions
```
SPM переиспользует уже скачанную версию из `Package.resolved` — без повторной загрузки.

## SPM Dependencies

- `swift-markdown-ui` (gonzalezreal) v2.4.1 — SwiftUI рендерер Markdown, тема `.gitHub`
  - Транзитивные: NetworkImage, cmark-gfm
- `swift-cmark` (swiftlang) v0.7.1 — cmark C библиотека, используется напрямую для AST-парсинга в редакторе
  - Продукты: `cmark-gfm` (core), `cmark-gfm-extensions` (strikethrough, table, tasklist, autolink)

## Releases

### v1 — Initial
NSDocument + NSTextView + SwiftUI Preview. Два режима Edit/Preview.

### v2 — Complete

**Паттерн тестируемости:** бизнес-логику выносить в pure free functions в `Editor/` (internal), тестировать через `@testable import EditMD`. Пример: `FormattingHelpers.swift`.

### v2 — Детали
- **Live Preview / cursor proximity** — маркеры (`#`, `**`, `*`, `>`, ссылки) скрыты везде кроме текущей строки. Паттерн: `rehighlight()`, `activeLine`, `isApplyingHighlight` (ренетранс-защита). Highlighting через cmark AST (`collectSpans` + `LineIndex` в `MarkdownHighlighter.swift`).
- **Настройки шрифта** — `EditorFontSettings` (singleton, UserDefaults), Format-меню ⌘=/⌘−
- **Счётчик слов/символов** — статус-строка внизу редактора, обновляется на каждый keystroke
- **Горячие клавиши форматирования** — Cmd+B / Cmd+I, оборачивают выделение в `**` / `*`
- **Поддержка .textbundle** — `FileWrapper`-based read/write, `TextBundleImageProvider` (AsyncImage + file:// URL), UTI `org.textbundle.package` (конформирует `com.apple.package`)
- **Cut/Copy/Paste** — Edit-меню + тулбар-кнопки (scissors/doc.on.doc/doc.on.clipboard), target=nil → responder chain

### v3 — Complete
- **SwiftUI App lifecycle + `.commands`** — `EditMDApp.swift` entry point, декларативное меню (Edit/Format)
- **Полное меню** — Edit (Undo/Redo/Cut/Copy/Paste/Select All), Format (Bigger/Smaller/Bold/Italic)

### v4 — Complete
- **Миграция на чистый SwiftUI** — `DocumentGroup` + `ReferenceFileDocument` вместо NSDocument
- **NSViewRepresentable** — `MarkdownTextView.swift` обёртка NSTextView (подсветка, форматирование, счётчик)
- **ContentView** — SwiftUI view с Edit/Preview toggle + `.toolbar`
- **@FocusedValue** — `FormatActions` для передачи Format-команд из Coordinator в меню
- **Удалены AppKit контроллеры** — AppDelegate, EditorWindowController, EditorViewController, MarkdownEditorView
- **Swift 6.2**, strict concurrency
- **49 тестов** — 28 highlighter + 14 formatting + 7 document

### v5 — Complete
- **Полная подсветка всех markdown-элементов** — 22 SpanKind (было 11)
- **GFM extensions** — strikethrough (`~~text~~`), таблицы, tasklists, autolinks через `cmark-gfm-extensions`
- **Новые элементы:** fenced/indented code blocks, thematic breaks (`---`/`***`/`___`), list markers (ordered/unordered), images (`![alt](url)`), inline/block HTML, strikethrough, table headers/delimiters
- **Парсер** — переход с `cmark_parse_document()` на явный parser API с GFM-расширениями
- **74 теста** — 53 highlighter + 14 formatting + 7 document
- **test-all-elements.md** — визуальный тестовый файл со всеми элементами

### v6 — In progress
- **Визуальная разметка цитат** — `MarkdownNSTextView` (подкласс NSTextView) рисует левую полосу 3pt через `drawBackground(in:)` используя `NSLayoutManager.enumerateLineFragments`
- **Вложенные цитаты** — глубина вычисляется через containment ranges; каждый уровень добавляет 20pt к x-позиции полосы и к `headIndent` текста
- **Исправлено обнаружение quoteMarker** — `lineIdx.offset(line, sc)` вместо `lineIdx.lineStart(line)` для корректной работы вложенных `>`
- **80 тестов** — 59 highlighter + 14 formatting + 7 document

## Conventions
