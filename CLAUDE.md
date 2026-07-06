# EditMD — Claude Guide

## Overview

Минималистичный Markdown редактор для macOS. Чистый SwiftUI App lifecycle + `DocumentGroup` + `ReferenceFileDocument`.
NSTextView обёрнут в `NSViewRepresentable` для подсветки синтаксиса.
**Три режима** (v18, переключатель в тулбаре + ⌘1/⌘2/⌘3 в View-меню):
- **Source** — сырой markdown без подсветки и декораций (`plainMode` в MarkdownTextView)
- **Visual** — сейчас гибрид v17 (live preview, маркеры на активной строке); целевое состояние — WYSIWYG (см. Roadmap)
- **Preview** — read-only рендер в WKWebView (свой HTML-визитор + GitHub-подобный CSS)

Кнопка 🎨 в тулбаре переключает тему (System/Comfortable/GitHub). Кнопка ☀/🌙 управляет `.preferredColorScheme`.
Меню — через SwiftUI `.commands` + `@FocusedValue` в `EditMDApp.swift`.

## Roadmap трёх режимов (принят 2026-07-06)

- **v18 ✅** — каркас режимов + plain Source + Preview (WKWebView)
- **v19** — линтер в Source: `MarkdownLint.swift` (pure `lint(text) -> [LintDiagnostic]`), правила: невалидные чекбоксы (`- [+]` → fix `[x]`), незакрытые маркеры, битые ссылки, `#без пробела`, незакрытый fence, кривые таблицы; отображение через `NSLayoutManager.addTemporaryAttribute` (не пачкает storage/undo), quick-fix в контекстном меню, счётчик `⚠ N` в статус-строке
- **v20** — Visual WYSIWYG фундамент: `isRichText = true`, рендерер `MarkdownToAttributed` + сериализатор `AttributedToMarkdown` с round-trip тестами-воротами (`serialize(render(md)) == normalize(md)`); непредставимые конструкции — read-only острова
- **v21** — Visual editing: семантика ввода (Enter в списках, Tab-вложенность, typing attributes), чекбоксы (кнопка/⌘⇧L, автоввод `[]`+space, Enter продолжает task-список), блочные декорации из drawBackground
- **v22** — таблицы через NSTextTable (разблокирован isRichText=true) + изображения NSTextAttachment
- **v23** — синхронизация режимов, полировка, чистка гибридного кода

**Принятые решения:** Visual — пропорциональный шрифт, Source — моноширинный. Source of truth — markdown-строка в MarkdownDocument; Visual сериализует при смене режима/сейве/дебаунсе. Undo-стек сбрасывается при смене режима. Гибрид v17 остаётся Visual-режимом до v20.

## Project Structure

```
editmd/
└── EditMD/
    ├── project.yml   # xcodegen конфиг — ЕДИНСТВЕННЫЙ источник структуры проекта
    ├── EditMD.xcodeproj/
    └── EditMD/
        ├── App/        EditMDApp.swift (entry point, DocumentGroup, SwiftUI commands), Info.plist
        ├── Document/   MarkdownDocument.swift (ReferenceFileDocument)
        ├── Editor/     MarkdownTextView.swift (NSViewRepresentable), MarkdownHighlighter.swift, FormattingHelpers.swift, EditorTheme.swift, MarkdownHTML.swift (Preview HTML-визитор)
        └── Views/      ContentView.swift, EditorFontSettings.swift, FocusedValues.swift, EditorMode.swift, MarkdownPreviewView.swift (WKWebView)
    EditMDTests/
        ├── MarkdownHighlighterTests.swift   # 59 XCTest кейсов для LineIndex + collectSpans (все markdown-элементы, включая codeMarker)
        ├── FormattingHelpersTests.swift     # 14 XCTest кейсов для wordAndCharCount + applyWrap
        ├── EditMenuTests.swift             # 7 XCTest кейсов для MarkdownDocument
        └── MarkdownHTMLTests.swift         # 12 XCTest кейсов для markdownHTMLBody/previewHTMLPage (эскейпинг, task list, таблицы, image resolver)
visual-audit.md  # чеклист визуального аудита всех 17 SpanKind + матрица light/dark состояний
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

### updateNSView: смена темы требует явной обработки
`coordinator.parent = self` обновляет `parent.theme`, но **не** обновляет `textView.theme` и не вызывает `rehighlight()`.
Без явной проверки переключение тем визуально не работает.
Паттерн: сравнивать по `theme.name` (т.к. `NSColor` не `Equatable`), затем обновлять textView и rehighlight:
```swift
if textView.theme.name != theme.name {
    textView.theme = theme
    textView.textContainerInset = NSSize(width: theme.editorInsetH, height: theme.editorInsetV)
    coordinator.rehighlight()
    return
}
```
`EditorTheme` содержит поле `var name: String` — идентификатор темы ("system", "comfortable", "github").

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

### Кэширование spans: `collectSpans` — чистая функция текста
`collectSpans` зависит только от текста, не от позиции курсора. Coordinator кэширует результат в `cachedSpans` и инвалидирует при `text != cachedText` (String `==` через pointer equality — O(1) для COW). При движении курсора spans берутся из кэша, пересчитывается только `activeRegion` и применяются атрибуты. Аналогично `cachedQuoteDepths` — глубина цитат вычисляется O(N) стеком при изменении текста.

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

### headIndent для вложенных blockquote (NSParagraphStyle — paragraph-level атрибут)
`headIndent` / `firstLineHeadIndent` применяется к **первому символу параграфа** — NSLayoutManager игнорирует стили на последующих символах той же строки.
Проблема: внутренний blockquote начинается на колонке 3 (после внешнего `> `), но параграф начинается на колонке 1. Применение `paragraphStyle` только к `quoteBody` range — НЕ работает для вложенных цитат.
Решение: расширять range до начала строки перед применением `paragraphStyle`:
```swift
storage.addAttribute(.foregroundColor, value: secondary, range: r)  // только quoteBody
let lineStart = (text as NSString).lineRange(for: NSRange(location: r.location, length: 0)).location
let paraRange = NSRange(location: lineStart, length: NSMaxRange(r) - lineStart)
storage.addAttribute(.paragraphStyle, value: para, range: paraRange)  // от начала строки
```
Outer (depth=0) применяется первым → headIndent=0 с lineStart. Inner (depth=1) применяется вторым → headIndent=20 переопределяет.

### applyHighlighting: activeRegion (v17: вычисляется в Coordinator.computeActiveRegion)
`applyHighlighting(to:in:activeRegion:)` принимает готовый `activeRegion`; его считает `Coordinator.computeActiveRegion(cursorPos:in:)` — строка курсора, расширенная блоками. Это позволяет показывать маркеры всего блока (все `>` в blockquote, оба fence в code block) когда курсор находится внутри блока. После добавления `codeBlockBody(language:)` проверку делать через pattern matching, не через `==`:
```swift
var activeRegion: NSRange? = activeLine
if let pos = cursorPos {
    for span in spans {
        let isBlock: Bool
        if case .quoteBody = span.kind { isBlock = true }
        else if case .codeBlockBody = span.kind { isBlock = true }
        else { isBlock = false }
        if isBlock && NSLocationInRange(pos, span.range) {
            activeRegion = activeRegion.map { NSUnionRange($0, span.range) } ?? span.range
        }
    }
}
```

### NSTextView flipped координаты
`NSTextView.isFlipped = true`. В flipped-системе y=0 вверху, растёт вниз:
- `rect.minY` = верхний визуальный край
- `rect.maxY` = нижний визуальный край
Для позиционирования overlay в **верхнем** правом углу code block: `y: paddedRect.minY + offset`.

### NSView overlays поверх NSTextView: не появляются при открытии документа
Две причины:

**1. Бесконечный цикл layout:** `layout()` → `updateOverlays()` → `removeFromSuperview` + `addSubview` → AppKit помечает view dirty → новый `layout()`. AppKit прерывает цикл принудительно, до завершения рендеринга.

**2. Race condition при открытии:** `bounds.width == 0` на первом вызове → кнопки получают отрицательный X.

**Решение — button pooling + NSLayoutManagerDelegate:**
- В `updateOverlays()` не удалять все кнопки — использовать пул: удалять/добавлять только разницу, `.frame` обновлять без `addSubview`
- `setFrameSize()` override не нужен — `layout()` покрывает все изменения bounds
- `NSLayoutManagerDelegate` обеспечивает первый корректный вызов после завершения layout
```swift
// Пул: удалить лишние / добавить недостающие
while codeOverlayButtons.count > codeBlockEntries.count {
    codeOverlayButtons.popLast()?.removeFromSuperview()
}
while codeOverlayButtons.count < codeBlockEntries.count {
    let btn = CodeCopyButton(frame: .zero)
    addSubview(btn)
    codeOverlayButtons.append(btn)
}
// Обновить только .frame и .isHidden — безопасно из layout()
for (index, entry) in codeBlockEntries.enumerated() {
    let btn = codeOverlayButtons[index]
    // ... позиционирование ...
    if btn.frame != newFrame { btn.frame = newFrame }
}

// NSLayoutManagerDelegate для initial timing:
nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                              didCompleteLayoutFor textContainer: NSTextContainer?,
                              atEnd layoutFinishedFlag: Bool) {
    guard layoutFinishedFlag else { return }
    MainActor.assumeIsolated {
        guard overlayNeedsUpdate else { return }
        overlayNeedsUpdate = false
        updateCodeBlockOverlays()
    }
}
```

### NSLayoutManagerDelegate + Swift 6 @MainActor конфликт
`NSLayoutManagerDelegate` не помечен `@MainActor`, но `NSTextView` (и его подклассы) — `@MainActor`. Конформанс вызывает ошибку "crosses into main actor-isolated code".
Решение: `nonisolated` на методе делегата + `MainActor.assumeIsolated` внутри (AppKit гарантирует вызов на главном потоке):
```swift
nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                              didCompleteLayoutFor textContainer: NSTextContainer?,
                              atEnd layoutFinishedFlag: Bool) {
    MainActor.assumeIsolated { /* доступ к @MainActor свойствам */ }
}
```

### NSButton adaptive background без CALayer
`CALayer.backgroundColor` требует `CGColor` — не поддерживает dynamic NSColor. Для адаптивного фона кнопки (light/dark) — переопределять `draw(_:)` в NSButton subclass:
```swift
final class CodeCopyButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.5, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        super.draw(dirtyRect)
    }
}
```

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

- `swift-markdown` (Apple) v0.7.3 — официальная Swift-обёртка cmark-gfm, используется в `MarkdownHighlighter.swift` через `MarkupWalker`
  - Продукт: `Markdown` (GFM extensions включены автоматически: table, strikethrough, tasklist)
  - `swift-cmark` подтягивается как транзитивная зависимость — импортировать напрямую не нужно

> `swift-markdown-ui` удалён в v12 — Preview режим убран из приложения.
> `swift-cmark` (прямая зависимость) удалена в v13 — заменена на `swift-markdown` MarkupWalker.

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

### v6 — Complete
- **Визуальная разметка цитат** — `MarkdownNSTextView` (подкласс NSTextView) рисует левую полосу 3pt через `drawBackground(in:)` используя `NSLayoutManager.enumerateLineFragments`
- **Вложенные цитаты** — глубина вычисляется через containment ranges; каждый уровень добавляет 20pt к x-позиции полосы и к `headIndent` текста
- **Исправлено обнаружение quoteMarker** — `lineIdx.offset(line, sc)` вместо `lineIdx.lineStart(line)` для корректной работы вложенных `>`
- **Исправлен headIndent для вложенных цитат** — `paragraphStyle` применяется от `lineStart`, а не от `quoteBody.location` (иначе NSLayoutManager игнорирует стиль для nested blockquotes)
- **Блочно-осведомлённая активная область** — `applyHighlighting(cursorPos:)` вычисляет `activeRegion` как union всех `quoteBody`/`codeBlockBody` spans содержащих курсор; все маркеры блока видны при редактировании
- **79 тестов** — 59 highlighter + 14 formatting + 7 document (без изменений, баги были в rendering логике)

### v7 — Complete
- **Фоновая панель code block** — `drawBackground(in:)` рисует полноширинный прямоугольник с +8pt вертикальными полями (`insetBy(dx: 0, dy: -8)`); цвет `NSColor(white: 0.5, alpha: 0.07)` — адаптируется к light/dark
- **Метка языка + кнопка копирования** — `CodeCopyButton` (NSButton subclass) в правом верхнем углу каждого code block; клик копирует содержимое без fence-строк; `⎘` для блоков без языка
- **`codeBlockBody(language: String)`** — SpanKind добавлен associated value; язык извлекается через `cmark_node_get_fence_info(node)` в `collectSpans`
- **`codeBlockEntries: [(range, language)]`** в `MarkdownNSTextView` вместо `codeBlockRanges`
- **79 тестов** — без изменений (паттерн-матчинг `if case .codeBlockBody = span.kind` работает с любым associated value)
- **Fix: overlay timing** — `NSLayoutManagerDelegate.layoutManager(_:didCompleteLayoutFor:atEnd:)` + `overlayNeedsUpdate` флаг; `nonisolated` + `MainActor.assumeIsolated` для Swift 6 strict concurrency
- **Fix: отступы кнопки** — top 2→6pt, right 12→6pt от paddedRect

### v8 — Complete
- **Кэширование spans** — `collectSpans` вызывается только при изменении текста, не при движении курсора; `cachedText`/`cachedSpans`/`cachedQuoteDepths` в Coordinator
- **O(N) quote depth** — стек `NSMaxRange` значений вместо O(N²) containment loop; использует depth-first порядок cmark (outer BLOCK_QUOTE → ENTER раньше inner)
- **79 тестов** — без изменений (оптимизация только в Coordinator, тесты покрывают pure functions)

### v9 — Complete
- **Отступы вокруг code blocks** — `paragraphSpacing = 16` на параграфе ДО блока, `paragraphSpacingBefore = 16` на параграфе ПОСЛЕ блока; применяется через post-processing loop по `codeBlockEntries` после spans loop, перед `storage.endEditing()`
- **Фон code block** — `insetBy(dx: 0, dy: -8)`, даёт 8pt внутреннего отступа
- **79 тестов** — без изменений

### paragraphSpacing + tinyFont — gotcha
`applyMarker` при inactive строке устанавливает `.font: NSFont.systemFont(ofSize: 0.01)` (tinyFont) на fence-строках code block. NSLayoutManager игнорирует `paragraphSpacingBefore`/`paragraphSpacing` на параграфах с near-zero-height шрифтом.

**Симптом:** spacing применён через NSParagraphStyle, билд OK, но визуально ничего не меняется.

**Решение:** применять spacing к параграфам СНАРУЖИ блока (с нормальным шрифтом) через post-processing loop по `codeBlockEntries` после spans loop (см. v9 в MarkdownTextView.swift).

### Формула визуальных полей code block

```
insetBy(dx: 0, dy: -N)  →  N pt внутреннего фона сверху/снизу (от fence до края панели)
paragraphSpacing = M    →  M pt между соседним параграфом и fence

Внешний зазор (текст → край фона) = M − N   (обязательно > 0!)
Внутренний отступ (край фона → первая строка кода) ≈ N
Итого от текста до кода = M

Текущие значения: N=8, M=16  →  внешний=8pt, внутренний=8pt, итого=16pt (~1 строка)
```

При изменении любого параметра проверять, что M > N.

### v10 — Complete
- **EditorTheme** — `EditorTheme.swift` в `Editor/`: все цвета, spacing, layout в одном `struct`
- **Два варианта:** `.system` (системные адаптивные NSColor) и `.comfortable` (те же цвета + увеличенные отступы)
- **MarkdownTextView** получил `var theme: EditorTheme = .system`; `MarkdownNSTextView` — `var theme: EditorTheme`
- **CodeCopyButton** получил `var fillColor: NSColor` вместо хардкода `NSColor(white:0.5, alpha:0.12)`
- **visual-audit.md** — все 17 SpanKind помечены [x]; 3 пункта light/dark/selection требуют ручной проверки

### v11 — Complete
- **codeMarker SpanKind** — inline code split на `codeMarker` (backtick-символы) + `code` (тело); `codeMarker` скрывается на неактивных строках через `applyMarker`, тело всегда показывается с orange + background
- **listMarker всегда видим** — убран `applyMarker` для `.listMarker`; маркеры (`-`, `*`, `1.`, task list `- `) всегда показываются в `accent` цвете
- **tableDelimiter всегда видим** — убран `applyMarker` для `.tableDelimiter`; `|` всегда показывается в `tertiary` цвете
- **59 тестов** — 3 inline code теста обновлены (expect codeMarker×2 + code body; было: code×1 на весь диапазон)

### v12 — Complete
- **Удалён Preview режим** — `EditorMode` enum, mode state, segmented picker, `MarkdownPreviewView.swift`
- **Кнопка light/dark** — `isDark: Bool` state в ContentView; `.preferredColorScheme(isDark ? .dark : .light)` на VStack; иконки `sun.max` / `moon`
- **Удалена зависимость `swift-markdown-ui`** — из `project.yml` (packages + dependencies); xcodeproj пересоздан через `xcodegen`
- **79 тестов** — без изменений

### codeMarker vs code span — разделение

`visitInlineCode` (SpanCollector) emits три span'а:
```swift
// bt = (r.length - inlineCode.code.utf16.count) / 2
let openRange  = NSRange(location: r.location, length: bt)             // codeMarker
let bodyRange  = NSRange(location: r.location + bt, length: bodyLen)   // code
let closeRange = NSRange(location: NSMaxRange(r) - bt, length: bt)     // codeMarker
```
`code` span (тело) получает: monospaced font + `inlineCodeBackground` + `inlineCodeColor`.
`codeMarker` (backtick-и) получает: `applyMarker(secondary)` — скрывается когда курсор не на строке.

### listMarker и tableDelimiter — NOT hidden

Элементы которые должны быть ВСЕГДА видимы (не вызывают `applyMarker`):
- `.listMarker` — accent color
- `.tableDelimiter` — tertiary color
- `.tableHeader`, `.thematicBreak`, все body spans

Элементы которые СКРЫВАЮТСЯ на неактивных строках через `applyMarker`:
- headingMarker, boldMarker, italicMarker, codeMarker, quoteMarker
- codeBlockFence, linkSyntax, imageSyntax, strikethroughMarker

### EditorTheme — структура
```
EditorTheme {
  Colors:    textColor, secondaryColor, tertiaryColor, accentColor,
             inlineCodeColor, imageColor, separatorColor,
             inlineCodeBackground, codeBlockBackground, copyButtonBackground,
             headingDividerColor, quoteBackground, tableRowBackground
  Typography: h1/h2/h3/h4PlusSizeOffset, smallFontOffset
  Spacing:   h1_2SpacingBefore, h3PlusSpacingBefore, headingSpacingAfter,
             quoteIndentStep, codeBlockHeadIndent, codeBlockPanelInset, codeBlockOuterSpacing,
             listItemSpacing
  Rendering: codeBlockCornerRadius
  Layout:    editorInsetH, editorInsetV, quoteBarWidth, quoteBarXOffset
}
```

### v13 — Complete
- **Миграция `collectSpans` на swift-markdown MarkupWalker** — заменён весь C API cmark-gfm на `import Markdown` + `SpanCollector: MarkupWalker`
- **Удалена прямая зависимость `swift-cmark`** — из `project.yml`; `swift-markdown` v0.7.3 подтягивает её транзитивно
- **`Document(parsing:)`** автоматически включает GFM: table, strikethrough, tasklist — без ParseOptions
- **79 тестов** — без изменений (контракт `collectSpans()` не менялся)

### swift-markdown: ключевые gotchas

**SourceRange — exclusive upperBound:** swift-markdown добавляет `+1` к cmark's endColumn. Для конвертации в NSRange — `lineIdx.offset()` для обоих bounds (НЕ `offsetAfter` для upperBound):
```swift
let loc = lineIdx.offset(src.lowerBound.line, src.lowerBound.column)
let end = lineIdx.offset(src.upperBound.line, src.upperBound.column)  // upper уже exclusive
```

**InlineCode.range включает backtick-и:** swift-markdown сам корректирует `startColumn - bt / endColumn + bt`. Формула:
```swift
let bt = (r.length - inlineCode.code.utf16.count) / 2
```

**isFenced: language=nil для обоих — indented и fenced-без-языка.** Различать по символу в тексте:
```swift
let isFenced = nsText.character(at: r.location) == 0x60 || ... == 0x7E  // ` or ~
```

**MarkupWalker: descendInto явный.** В переопределённых методах нужно вызывать `descendInto(node)` — иначе children не посещаются. `defaultVisit` (для не-переопределённых методов) вызывает descendInto автоматически.

### v14 — Complete
- **`.github` тема** — `NSColor(name:dynamicProvider:)` с адаптивными hex-цветами из MarkdownUI GitHub-темы; хелпер `gh(lightHex, darkHex)` в `EditorTheme` extension
- **Heading weight** — `.bold` → `.semibold` для всех заголовков
- **H1/H2 dividers** — горизонтальная линия 1pt под H1/H2; `headingDividerRanges: [NSRange]` в Coordinator → MarkdownNSTextView → `drawBackground(in:)`
- **Rounded code blocks** — `codeBlockCornerRadius: CGFloat` в EditorTheme; `NSBezierPath(roundedRect:xRadius:yRadius:).fill()` в drawBackground
- **Blockquote background** — `quoteBackground: NSColor` в EditorTheme; заливка bgRect перед левой полосой в drawBackground
- **3 новых SpanKind** — `listItemBody` (paragraph spacing), `tableRow` (alternating row background), `taskListMarker(done:)` (task list coloring)
- **Alternating table rows** — `visitTable` эмитит `.tableRow` для нечётных строк тела; `tableRowBackground` через `.backgroundColor` NSTextStorage атрибут
- **Task list styling** — text-scan для `"[ ] "` / `"[x] "` после маркера; done-items получают strikethrough + secondaryColor на body
- **79 тестов** — без изменений (новые spans аддитивны, тесты фильтруют по SpanKind)
- **ContentView** — `theme: .github` подключён; `@State var theme: EditorTheme` + `Menu` в тулбаре для переключения System/Comfortable/GitHub
- **`ghAlpha(light:dark:)` хелпер** — для полупрозрачных adaptive-цветов (white/black с alpha); `listItemBody` упрощён (depth убран как unused)
- **Blockquote drawBackground** — один проход `enumerateLineFragments` вместо двух (bg union + bar rects за один цикл)

### v15 — Complete
- **Hanging indent для списков** — `listItemBody(textStartCol: Int)` хранит 1-based колонку начала текста; `headIndent = (textStartCol-1) * charWidth`, `firstLineHeadIndent = 0`; применяется к первому параграфу пункта
- **Visual bullet rendering** — `listMarker(ordered: Bool, depth: Int)`; unordered маркеры скрываются через `NSColor.clear` (layout width сохраняется); `drawBackground` рисует `•`/`◦`/`▪` по depth; ordered маркеры всегда видимы
- **listBlock span** — `visitUnorderedList`/`visitOrderedList` эмитят `.listBlock`; добавлен в activeRegion expansion → весь блок списка активен при курсоре внутри любого пункта
- **79 тестов** — обновлён паттерн `if case .listMarker(_, _) = $0.kind` (добавлены associated values)

### v18 — Complete
- **Три режима** — `EditorMode` (source/visual/preview), segmented picker в тулбаре, ⌘1/⌘2/⌘3 через `CommandGroup(before: .toolbar)` + `@FocusedValue(\.editorMode)` (Binding); режим хранится в `@AppStorage("editorMode")`
- **Source (plain)** — `plainMode: Bool` в MarkdownTextView; guard в начале `rehighlight()` (сбрасывает pendingEdit); entry-массивы остаются пустыми → drawBackground/overlays не рисуют ничего
- **Preview** — `MarkdownPreviewView` (WKWebView): свой `HTMLBodyVisitor` в `MarkdownHTML.swift` + full-page CSS (`color-scheme: light dark`, системные цвета Canvas/CanvasText → следует за ☀/🌙 без перезагрузки); клики по ссылкам → NSWorkspace (browser), Coordinator кэширует `lastRenderedContent`
- **Картинки в Preview** — data-URI инлайнинг (`dataURI(for:baseDir:)`): loadHTMLString не даёт file://-доступ к субресурсам; baseDir = папка .md или корень .textbundle; лимит 8 MB, MIME по расширению
- **101 тест** — +12 `MarkdownHTMLTests`
- **Смена режима** — ветки switch в ContentView = разные structural identity → NSView пересоздаётся, undo-стек сбрасывается (осознанное решение)
- **statusBar в Preview** — счёт слов напрямую из `document.content` (нет editor-коллбеков)

### v18 — gotchas
- **HTMLFormatter из swift-markdown НЕ использовать для Preview** — не эскейпит text/code (`<div>` в code block ломает страницу), заголовки через `plainText` теряют inline-разметку. Свой визитор в `MarkdownHTML.swift`
- **`<li>` + вложенный `<p>`** — swift-markdown всегда оборачивает контент пункта в Paragraph; блочный `<p>` уносит текст под чекбокс/буллит. Визитор разворачивает первый Paragraph пункта inline (GitHub tight-стиль), остальные children рендерит как есть
- **WKNavigationDelegate + Swift 6** — в macOS 26 SDK протокол @MainActor-аннотирован: `@MainActor final class Coordinator: NSObject, WKNavigationDelegate` с обычными методами собирается без nonisolated-обвязки
- **xcodebuild через `| head`** — SIGPIPE убивает сборку на середине; логировать в файл, потом grep

### v17 — Complete
- **Кликабельные ссылки** — `linkText(destination: String?)`; `linkEntries` в MarkdownNSTextView; Cmd+click открывает URL через NSWorkspace; tooltip с адресом (`.toolTip` атрибут); обычный клик ставит курсор
- **Setext-заголовки** — `visitHeading` различает ATX (первый символ `#`) и setext; для setext маркер = underline-строка (`===`/`---`), а не префикс текста заголовка
- **Task list через `ListItem.checkbox`** — замена text-scan на API; фикс `- [x]` на EOF
- **Клик по чекбоксу** — `mouseDown` hit-test по `checkboxRect(for:)` (общий хелпер отрисовки и hit-теста); toggle `[ ]`↔`[x]` через `shouldChangeText`/`didChangeText` (undo работает, курсор не двигается)
- **Фикс буллита `- [Link](url)`** — подавление буллита по `taskListMarker`-спанам, не по символу `[`
- **Инкрементальная переразметка** — `spanDiffDirtyRange` (pure, MarkdownHighlighter.swift): диф старых/новых spans, префикс и сдвинутый суффикс пропускаются; `.listBlock` исключён из диффа (правка в списке красит только пункт). Три пути в `rehighlight`: edit (diff dirty) / full (первый запуск, тема, шрифт) / selection (только old∪new activeRegion, ранний выход при равенстве)
- **`NSTextStorageDelegate.didProcessEditing`** — точный editedRange+delta в `pendingEdit`; фильтр `.editedCharacters` (атрибутные проходы не считаются правкой); убрано O(N)-сравнение строк на движение курсора
- **`ensureLayout(forCharacterRange:)`** — только до конца последнего code-блока вместо всего документа; без code-блоков layout не форсируется
- **89 тестов** — +5 (setext ×2, link destination, taskListMarker spans, `- [Link]` не tasklist) +5 `SpanDiffDirtyRangeTests`

### v17 — ключевые инварианты инкрементальной покраски
- **Overlay entries всегда пересобираются из ПОЛНОГО списка spans** (entry-пасс перед beginEditing), атрибуты пишутся только в dirty range — массивы на textView заменяются целиком
- **Маркеры видимости**: dirty обязан включать old∪new activeRegion, если они различаются (mapRange сдвигает старый регион на delta правки)
- **dirty расширяется на ±1 строку** (`expandToAdjacentParagraphs`) — соседние параграфы несут code-block spacing
- **Quote/spacing циклы гейтятся** по пересечению с dirty (`paraRange`/`prevRange`/`nextRange`)
- **Страховка**: в selection-пути при несовпадении длины текста с кэшем — полный reparse

### v16 — Complete
- **Надёжная отрисовка буллитов** — заменён `lineFragmentRect + location(forGlyphAt:)` на `boundingRect(forGlyphRange:in:)` (TextKit 2 fix); радиус `0.22 * lineHeight` вместо `0.18 * min(height, charW)`; убрана проверка `intersects(rect)`
- **Графические чекбоксы** — task list markers (`[ ]`/`[x]`) скрываются через `NSColor.clear` на неактивных строках; в `drawBackground` рисуются rounded-corner квадраты (14pt, `xRadius: 3.5`); done → `accentColor` fill + белая галочка; todo → `secondaryColor` stroke
- **Подавление буллита для task list** — в `.listMarker` case проверяем символ `[` (0x5B) после маркера: `bulletEntries.append(..., shouldDraw: !active && !isTaskList)`
- **`taskListEntries`** — новый массив в Coordinator и MarkdownNSTextView; передаётся через `textView?.taskListEntries = taskListEntries`
- **79 тестов** — без изменений (изменения только в rendering логике)

### task list checkboxes — паттерн подавления буллита
Task list items (`- [ ]`, `- [x]`) имеют и `.listMarker`, и `.taskListMarker` span. Чтобы не рисовать буллит поверх чекбокса — проверка по реальным `taskListMarker`-спанам (v17), НЕ по одному символу `[`:
```swift
var taskMarkerLocs = Set<Int>()
for s in spans { if case .taskListMarker = s.kind { taskMarkerLocs.insert(s.range.location) } }
// в entry-пассе:
let isTaskList = taskMarkerLocs.contains(NSMaxRange(s.range))
```
Проверка одного символа `[` ошибочно подавляла буллит у пунктов вида `- [Link](url)`.

### NSColor dynamic provider — правильный паттерн
`NSColor(name:dynamicProvider:)` для adaptive hex-цветов. Нужно проверять **все 4** dark appearance варианта:
```swift
NSColor(name: nil) { appearance in
    switch appearance.name {
    case .darkAqua, .vibrantDark,
         .accessibilityHighContrastDarkAqua,
         .accessibilityHighContrastVibrantDark:
        return darkColor
    default:
        return lightColor
    }
}
```
Если проверять только `.darkAqua` — тема не сработает в accessibility High Contrast режимах.

Для **полупрозрачных** adaptive-цветов (white/black с alpha) используется `ghAlpha(light:dark:)` хелпер в `EditorTheme` — шаблон аналогичный `gh()`, но принимает `CGFloat` alpha вместо hex:
```swift
private static func ghAlpha(light: CGFloat, dark: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        switch appearance.name {
        case .darkAqua, .vibrantDark, ...darkAqua variants...:
            return NSColor(white: 1.0, alpha: dark)
        default:
            return NSColor(white: 0.0, alpha: light)
        }
    }
}
// Использование: quoteBackground: ghAlpha(light: 0.025, dark: 0.03)
```

### visitTable — объявлять `el` явно
`el` (последняя строка таблицы) не объявляется автоматически в `visitTable`. Обязательно добавить перед использованием:
```swift
let sl = srcRange.lowerBound.line
let el = srcRange.upperBound.line  // ← без этого "cannot find 'el' in scope"
```

### Task list: `ListItem.checkbox` ЕСТЬ в swift-markdown v0.7.3
Ранее здесь ошибочно значилось, что API отсутствует. `ListItem.checkbox: Checkbox?` (`.checked`/`.unchecked`) существует и используется с v17 — авторитетнее text-scan:
```swift
if let checkbox = listItem.checkbox {
    let cbStart = markerStart + markerLen
    if cbStart + 3 <= nsText.length, nsText.character(at: cbStart) == 0x5B {  // '['
        spans.append(Span(range: NSRange(location: cbStart, length: 3),
                          kind: .taskListMarker(done: checkbox == .checked)))
    }
}
```

### List item hanging indent — firstLineHeadIndent = 0 + headIndent
Вложенные списки содержат literal пробелы в исходнике (`  - subitem`). Применять **только**:
- `firstLineHeadIndent = 0` — первая строка позиционируется литеральными символами
- `headIndent = CGFloat(textStartCol - 1) * charWidth` — wrapped строки выравниваются по тексту

`charWidth = baseFont.maximumAdvancement.width` — точно для monospace (редактор использует `NSFont.monospacedSystemFont`).
Применять только к **первому параграфу** пункта (`lineRange(for:)`), иначе continuation-параграфы (blank line + indent) тоже получают неверный indent.

Прежнее правило "не применять headIndent" было связано с установкой `firstLineHeadIndent = headIndent = N` — это создавало двойной отступ (стиль + literal пробелы). Паттерн `firstLineHeadIndent = 0` + `headIndent = N` не создаёт двойного отступа.

`textStartCol` передаётся в `listItemBody(textStartCol: Int)` — 1-based column где начинается текст после маркера (`sc + markerLen` в `visitListItem`).

### Скрытие маркеров в списках — NSColor.clear, не tinyFont
Для unordered маркеров (`- `, `* `) на неактивных строках использовать **только** `.foregroundColor = NSColor.clear`.
`tinyFont` (0.01pt) уменьшает ширину символа → текст после маркера смещается влево → hanging indent ломается.
`NSColor.clear` делает символ прозрачным но сохраняет layout width — glyph занимает то же место.

### drawBackground: boundingRect vs lineFragmentRect + location (TextKit 2)
В TextKit 2 compatibility mode `location(forGlyphAt:)` ненадёжен — возвращает 0 или некорректные значения для символов, layout которых ещё не завершён. Использовать `boundingRect(forGlyphRange:in:)`:
```swift
guard let textContainer = self.textContainer else { return }
let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { continue }
let symbolRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
guard symbolRect.width > 0, symbolRect.height > 0 else { continue }
// Координаты в view: добавить textContainerInset
let cx = inset.width + symbolRect.midX
let cy = inset.height + symbolRect.midY
```
`boundingRect` форсирует генерацию глифов и возвращает точный rect. Убирать проверку `intersects(rect)` — macOS сама отсекает невидимые регионы, ручная проверка с вычисленными координатами часто отсекает лишнее.

Нужно ли рисовать символ — хранить в `shouldDraw: Bool` поле самого entry-tuple (устанавливать в `applyHighlighting`). Проверка alpha из storage (`markerColor?.cgColor.alpha == 0`) — устаревший паттерн, заменён на `shouldDraw`.

### listBlock span — activeRegion для всего блока списка
Для корректного отображения маркеров всего блока (все `- ` видимы пока курсор в любом пункте списка) нужен span на весь `UnorderedList` / `OrderedList`:
```swift
// SpanKind:
case listBlock  // full UnorderedList/OrderedList range

// SpanCollector:
mutating func visitUnorderedList(_ list: UnorderedList) {
    if let r = list.range.flatMap({ nsRange(for: $0) }) {
        spans.append(Span(range: r, kind: .listBlock))
    }
    descendInto(list)
}
// аналогично visitOrderedList
```
Добавить `.listBlock` в activeRegion expansion рядом с `.quoteBody`/`.codeBlockBody`:
```swift
case .quoteBody, .codeBlockBody, .listBlock:
    if NSLocationInRange(pos, span.range) {
        activeRegion = activeRegion.map { NSUnionRange($0, span.range) } ?? span.range
    }
```
`case .listBlock: break` в основном switch (нет прямого styling).

### drawBackground: fullWidth объявлять на верхнем уровне
Если несколько секций drawBackground используют `fullWidth = bounds.width - inset.width * 2`, объявлять одну переменную вверху функции, не повторять в каждой секции — иначе closure capture lists дублируются и код читается хуже.

### drawBackground: один проход enumerateLineFragments для bg + bar
Blockquote-секция рисует фон (bgRect) и левые полосы (barRects). Делать это за **один** вызов `enumerateLineFragments`, собирая bgRect union и массив barRects, затем рисовать в порядке: bg → bars:
```swift
var bgRect = NSRect.null; var barRects: [NSRect] = []
layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { ... in
    bgRect = ...; barRects.append(...)
}
if hasQuoteBg && !bgRect.isNull { theme.quoteBackground.setFill(); bgRect.fill() }
theme.separatorColor.setFill()
for barRect in barRects where barRect.intersects(rect) { barRect.fill() }
```
Два отдельных вызова `enumerateLineFragments` на одном range — расточительно.

### Таблицы: два подхода попробованы и отброшены (откат на v12)

**Подход 1 — Overlay с per-cell NSTextView editing (v13–v14):**
TableOverlayView + CellTextView per ячейке + TableOverlayDelegate (CRUD строк/столбцов). Проблемы: stale NSRange после rehighlight, сложный deferred commit, overlay timing при открытии. Reverted.

**Подход 2 — Toggle по позиции курсора:**
Cursor вне таблицы → read-only overlay (hitTest → nil), текст скрыт; cursor внутри → plain markdown. Проблема: cmark-gfm расширяет диапазон `tableBody` на следующий параграф без blank line → логика "cursor inside/outside" ломается. Reverted.

**Корень проблемы:** `NSTextTable` не работает при `isRichText = false`. Overlay-подходы упираются в NSRange-десинхронизацию после rehighlight.

**Следующая попытка:** рассматривать только варианты без overlay — либо `isRichText = true` + NSTextTable, либо plain text с минимальной подсветкой.

## Conventions
