# EditMD — Claude Guide

## Overview

Минималистичный Markdown редактор для macOS. Чистый SwiftUI App lifecycle + `DocumentGroup` + `ReferenceFileDocument`.
NSTextView обёрнут в `NSViewRepresentable` для подсветки синтаксиса.
Только режим Edit (NSTextView). Кнопка ☀/🌙 в тулбаре управляет `.preferredColorScheme`.
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
        ├── Editor/     MarkdownTextView.swift (NSViewRepresentable), MarkdownHighlighter.swift, FormattingHelpers.swift, EditorTheme.swift
        └── Views/      ContentView.swift, EditorFontSettings.swift, FocusedValues.swift
    EditMDTests/
        ├── MarkdownHighlighterTests.swift   # 59 XCTest кейсов для LineIndex + collectSpans (все markdown-элементы, включая codeMarker)
        ├── FormattingHelpersTests.swift     # 14 XCTest кейсов для wordAndCharCount + applyWrap
        └── EditMenuTests.swift             # 7 XCTest кейсов для MarkdownDocument
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

### applyHighlighting: cursorPos вместо activeLine
`applyHighlighting` принимает `cursorPos: Int?` и вычисляет блочно-осведомлённый `activeRegion` внутри функции (после `collectSpans`). Это позволяет показывать маркеры всего блока (все `>` в blockquote, оба fence в code block) когда курсор находится внутри блока. После добавления `codeBlockBody(language:)` проверку делать через pattern matching, не через `==`:
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

- `swift-cmark` (swiftlang) v0.7.1 — cmark C библиотека, используется напрямую для AST-парсинга в редакторе
  - Продукты: `cmark-gfm` (core), `cmark-gfm-extensions` (strikethrough, table, tasklist, autolink)

> `swift-markdown-ui` удалён в v12 — Preview режим убран из приложения.

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

`CMARK_NODE_CODE` emits три span'а:
```swift
let openRange  = NSRange(location: fullLoc, length: bt)          // codeMarker
let bodyRange  = NSRange(location: fullLoc + bt, length: ...)    // code
let closeRange = NSRange(location: bodyEnd, length: bt)          // codeMarker
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
             inlineCodeBackground, codeBlockBackground, copyButtonBackground
  Typography: h1/h2/h3/h4PlusSizeOffset, smallFontOffset
  Spacing:   h1_2SpacingBefore, h3PlusSpacingBefore, headingSpacingAfter,
             quoteIndentStep, codeBlockHeadIndent, codeBlockPanelInset, codeBlockOuterSpacing
  Layout:    editorInsetH, editorInsetV, quoteBarWidth, quoteBarXOffset
}
```

### Таблицы: два подхода попробованы и отброшены (откат на v12)

**Подход 1 — Overlay с per-cell NSTextView editing (v13–v14):**
TableOverlayView + CellTextView per ячейке + TableOverlayDelegate (CRUD строк/столбцов). Проблемы: stale NSRange после rehighlight, сложный deferred commit, overlay timing при открытии. Reverted.

**Подход 2 — Toggle по позиции курсора:**
Cursor вне таблицы → read-only overlay (hitTest → nil), текст скрыт; cursor внутри → plain markdown. Проблема: cmark-gfm расширяет диапазон `tableBody` на следующий параграф без blank line → логика "cursor inside/outside" ломается. Reverted.

**Корень проблемы:** `NSTextTable` не работает при `isRichText = false`. Overlay-подходы упираются в NSRange-десинхронизацию после rehighlight.

**Следующая попытка:** рассматривать только варианты без overlay — либо `isRichText = true` + NSTextTable, либо plain text с минимальной подсветкой.

## Conventions
