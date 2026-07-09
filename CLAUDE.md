# EditMD — Claude Guide

## Overview

Минималистичный Markdown редактор для macOS. Чистый SwiftUI App lifecycle. **С v28 — `WindowGroup` + собственный `DocumentRegistry`** (уход от `DocumentGroup`): главное окно с файловым сайдбаром меняет файл на месте, отдельные lite-окна — value-based `WindowGroup(for: URL)`; `MarkdownDocument` = модель контента, сериализация/IO в `DocumentStore.swift`. NSTextView обёрнут в `NSViewRepresentable` для подсветки синтаксиса. **Три режима** (переключатель в тулбаре + ⌘1/⌘2/⌘3 в View-меню, курсор/скролл сохраняются между режимами):

- **Source** — сырой markdown, моноширинный; подсветка синтаксиса по настройкам (per-mode элементы: заголовки/жирное/код/цитаты/ссылки — размер/вес/цвет через `collectSpans`, v27) + линтер (14 правил, quick-fix) — `SourceTextView.swift`
- **Visual** — WYSIWYG на attributed-модели: маркеров в тексте нет, семантика в кастомных атрибутах, пропорциональный шрифт, таблицы NSTextTable, картинки, синхронная сериализация в markdown — `VisualTextView.swift`
- **Preview** — read-only рендер в WKWebView (свой HTML-визитор + GitHub-подобный CSS) — `MarkdownPreviewView.swift`

Кнопка 🎨 в тулбаре переключает тему (System/Comfortable/GitHub). Кнопка ☀/🌙 управляет `.preferredColorScheme`. Меню — через SwiftUI `.commands` + `@FocusedValue` в `EditMDApp.swift` (File-меню теперь ручное — DocumentGroup его больше не даёт). **Файловый сайдбар** (⌃⌘S, кастомный HStack-сплит + divider) — вкладки **Files/Outline/Git**: Files = несколько workspace-папок (скрытые файлы, пины) + «Открытые файлы», клик = замена файла в окне; Outline = заголовки документа; Git = workspace-scoped status + Commit/Push/Diff (`WorkspaceSidebar.swift` + `GitSidebar.swift` + `OutlineSidebar.swift`, `WorkspaceModel.swift`). **Сплит редактор+превью** (⌥⌘P) — Source/Visual слева + живой Preview справа. Тулбар — плоские иконочные кнопки в стиле agterm (многосостоянные SF Symbols, тултипы с шорткатами). **Settings-окно** (⌘,) — вкладки General/Source/Visual/Preview: шрифт/отступы/ширина колонки по каждому режиму отдельно, тема + цвета в General — `EditorSettings.swift` + `SettingsView.swift`.

## Версии — краткая карта

> **Полная история версий** — детали реализации и per-version gotchas каждого релиза — в **`docs/HISTORY.md`**. Перед работой над областью, которую строила конкретная версия, читай её раздел там.

- **v1–v17** — путь до трёх режимов: NSDocument → чистый SwiftUI (`DocumentGroup`), подсветка cmark C API → swift-markdown, гибрид-редактор (удалён в v23)
- **v18** — каркас трёх режимов + Preview (WKWebView)
- **v19** — линтер в Source (14 правил, quick-fix)
- **v20** — WYSIWYG-модель: `MarkdownToAttributed` + `AttributedToMarkdown`, round-trip ворота
- **v21** — Visual = настоящий WYSIWYG (`VisualTextView.swift`)
- **v22** — таблицы NSTextTable + картинки + курсор/скролл между режимами
- **v23** — чистка (гибрид v17 удалён, Source = `SourceTextView`), ⌘K ссылки в Visual
- **v24** — сайдбар-оглавление + сплит редактор/превью + agterm-тулбар
- **v25** — паттерны FSNotes: интерактивный Preview, Back/Forward, Edit▸Find, полное Format-меню
- **v26** — Settings-окно (⌘,): per-mode шрифт/отступы/ширина колонки
- **v27** — настройки применяются честно + per-mode ElementStyles + подсветка Source
- **v28** — `WindowGroup` + `DocumentRegistry` (уход от DocumentGroup), файловый сайдбар + workspace
- **v29** — большие файлы не вешают app (hash `MDBlock`, table-island, heavy-гейт) + дерево подпапок
- **v30** — wiki-links `[[Note|alias]]` во всех трёх режимах + `WikiLinkResolver`
- **v31** — большие таблицы рисуются как таблицы в Visual (виртуализированный grid, read-only)
- **v32** — виртуальное выравнивание колонок таблиц в Source (`.kern`, файл не меняется)
- **v33** — YAML frontmatter «как в Obsidian» (Visual + Preview) + подсветка `yaml`-код-блоков во всех режимах
- **v34** — внешние правки открытого файла: watch + auto-reload/conflict, unified diff, line gutter, commit/push (app 0.34.3)
- **v35** — вкладка Git в сайдбаре, workspace-scoped status, perf-фиксы (app 0.35.1)

**Осталось на будущее:** remote-картинки в Visual (async загрузка), undo через границы переключения режимов, CRUD столбцов таблиц, drag&drop картинок, per-document запоминание режима (идея FSNotes, отложена), поиск внутри Preview (WKWebView.find / кастомная панель как MPreviewFindPanel в FSNotes), **полноценная работа с большими таблицами** (сейчас read-only virtualized grid — нужно редактирование + горизонтальный скролл, см. `docs/HISTORY.md`, «v31» → идеи), **перенос широких ячеек в Visual-grid** (v32 в Source перенос невозможен — plain text; wrap уместен в нарисованной сетке v31: многострочная ячейка + рост высоты строки). Wiki-links Фаза-5 хвосты: стиль несуществующих ссылок, heading/block-скролл, `[[`-автокомплит.

**Принятые решения:** Visual — пропорциональный шрифт, Source — моноширинный. Source of truth — markdown-строка в MarkdownDocument; Visual сериализует при смене режима/сейве/дебаунсе. Undo-стек сбрасывается при смене режима. Гибрид v17 остаётся Visual-режимом до v20.


## Ключевые инварианты (сводка; детали и контекст — в `docs/HISTORY.md`)

- **Round-trip держит `.raw`** — display-текст островов (большие таблицы, frontmatter) косметичен и может отличаться от исходника; сериализатор читает `.raw`-атрибут дословно (v31/v33).
- **Не класть тяжёлые значения в атрибуты NSAttributedString без дешёвого `hash(into:)`** — NSTextStorage хеширует значения атрибутов при `fixAttributes`; `String.count` = O(n), в hot-path не вызывать (v29).
- **Два независимых порога**: `maxNativeTableCells` (island vs `NSTextTable` в Visual, по ячейкам) и `markdownIsHeavy` (plain vs подсветка в Source, по размеру+таблицам) — не путать (v29).
- **NSTextTable: один shared инстанс на таблицу**; NSTextTable вообще не работает при `isRichText=false` (v22).
- **Source-подсветка — только реальные storage-атрибуты, не temporary** — temporary-атрибуты не влияют на layout/размер шрифта (v27).
- **`textView.string = …` / `setAttributedString` синхронно дёргают `textViewDidChangeSelection`** — читать сохранённую позицию ДО установки текста (v22).
- **Виртуализация больших таблиц = арифметика по фиксированной высоте строки** (`y = top + row*rowH`), НЕ `enumerateLineFragments` по всему острову; `.byClipping` на параграфе обязателен (v31).
- **Выравнивание таблиц в Source — display-only `.kern`**, не вставка пробелов; чистить `.kern` из `typingAttributes` (v32).
- **Три режима — три независимых парс-пути**: Source=`collectSpans`, Visual=`VisualRenderer`, Preview=`HTMLBodyVisitor` — сквозную фичу (frontmatter, wiki-links) проводить через все три (v33).
- **Restamp-паттерн** для смены блок-атрибутов (`shouldChangeText` → addAttribute → `didChangeText`, undo работает) + флаг `isMutating` против рекурсии `textDidChange` (v21).
- **Свой flush файла обновляет `knownModDate` + re-arm watch** — иначе своя запись принимается за external change (v34).
- **WKNavigationDelegate в macOS 26 SDK** — только async-вариант `decidePolicyFor` (closure-вариант «nearly matches» и молча не вызывается) (v24).
- **Диагностика зависаний — `sample <pid> 3`**, не догадки: изолированный юнит-замер может не воспроизвести проблему, живой процесс покажет точный стек (v29).

## Project Structure

```
editmd/
└── EditMD/
    ├── project.yml   # xcodegen конфиг — ЕДИНСТВЕННЫЙ источник структуры проекта
    ├── EditMD.xcodeproj/
    └── EditMD/
        ├── App/        EditMDApp.swift (entry point: Window("main")+WindowGroup(for:URL), ручное File-меню, commands), AppState.swift (currentURL главного окна + роутинг открытия), AppDelegate.swift (Finder open→AppState), Info.plist
        ├── Document/   MarkdownDocument.swift (модель контента, всё ещё ReferenceFileDocument — но сцену больше не питает), DocumentStore.swift (общий core сериализации .md/.textbundle + DocumentRegistry: одна модель на URL, refcount, autosave)
        ├── Editor/     SourceTextView.swift (Source: подсветка + линт; `makeSourceHighlightedString` shared), VisualTextView.swift (Visual: WYSIWYG), MarkdownHighlighter.swift, MarkdownOutline.swift, FormattingHelpers.swift, EditorTheme.swift, MarkdownHTML.swift, MarkdownLint.swift, MarkdownToAttributed.swift + AttributedToMarkdown.swift, Frontmatter.swift, MarkdownTableGrid.swift, WikiLink.swift, TextDiff.swift, LineChangeTracker.swift, LineNumberRulerView.swift, GitCommitWatcher.swift (`GitCLI` + detect-commit)
        └── Views/      ContentView.swift (layout + external-change chip + git info chip), FileEditor.swift (DocHost + MainWindowView), ExternalChangeUI.swift, GitUI.swift (Commit sheet + Push confirm + status chip + workspace git snapshot), GitSidebar.swift (Git navigator tab), WorkspaceModel.swift, WorkspaceSidebar.swift, OutlineSidebar.swift, EditorSettings.swift, SettingsView.swift, FocusedValues.swift, EditorMode.swift, EditorPositionStore.swift, MarkdownPreviewView.swift, DocumentHistory.swift, WelcomeView.swift
    EditMDTests/
        ├── MarkdownHighlighterTests.swift   # 53 XCTest кейса для LineIndex + collectSpans (все markdown-элементы)
        ├── FormattingHelpersTests.swift     # 14 XCTest кейсов для wordAndCharCount + applyWrap
        ├── EditMenuTests.swift             # 7 XCTest кейсов для MarkdownDocument
        ├── MarkdownHTMLTests.swift         # 12 XCTest кейсов для markdownHTMLBody/previewHTMLPage (эскейпинг, task list, таблицы, image resolver)
        ├── MarkdownLintTests.swift         # 30 XCTest кейсов для lint() — все 14 правил + анти-FP гарды + применение fix'ов
        ├── MarkdownOutlineTests.swift      # 9 XCTest кейсов для markdownOutline (уровни, plainText, UTF-16 оффсеты, fence/setext/blockquote)
        ├── RoundTripTests.swift            # 55 XCTest кейсов render/serialize: stable-фикстуры, идемпотентность, HTML-отпечаток, корпус
        ├── DocumentStoreTests.swift        # 7 кейсов: round-trip .md/.textbundle + assets, DocumentRegistry (shared-model/refcount, save-on-dirty, flush-on-release)
        ├── WorkspaceModelTests.swift       # 5 кейсов: скан-фильтрация, hide/unhide, персист скрытых по пути, пины, noteOpened
        └── FrontmatterTests.swift          # 22 кейса: frontmatterRange (детект/фенсы/малформ), parseFrontmatterProperties (scalar/flow/block-list/comment/colon-в-значении), yamlLineSegments (лосслесс/классификация), HTML-таблица + yaml-спаны, Visual round-trip
docs/HISTORY.md  # история версий v1–v35: детали релизов + per-version gotchas
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

### Оконная модель (v28 — заменила DocumentGroup)

> **Историческое:** до v28 `EditMDApp.swift` использовал `DocumentGroup(newDocument:editor:)` (окно=документ), которое само давало File-меню/автосейв/`.textbundle`/роутинг Finder. С v28 это заменено (нужна была «замена файла в том же окне»). Детали — `docs/HISTORY.md`, раздел «v28 — Complete».

`EditMDApp.swift` объявляет две сцены: `Window("EditMD", id:"main")` (главное workspace-окно, слушает `AppState.currentURL`) и `WindowGroup(for: URL.self)` (отдельные lite-окна). `AppDelegate.application(_:open:)` роутит Finder-открытия через `AppState` по настройке `general.liteMode`. Документы резолвятся через `DocumentRegistry` (одна модель на URL, refcount) — `DocHost` в `FileEditor.swift` делает acquire/release по идентичности вью. File-меню (New/Open/Open Folder/Save/Save As) собрано вручную; сохранение/автосейв — через реестр.

### NSTextView через NSViewRepresentable

`MarkdownTextView.swift` — обёртка NSTextView. Coordinator содержит:

- NSTextViewDelegate (textDidChange, textViewDidChangeSelection)
- Подсветка синтаксиса (applyHighlighting, rehighlight)
- Форматирование (toggleBold, toggleItalic, wrapSelection)
- Счётчик слов/символов
- Обработка изменения шрифта

### @FocusedValue для меню Format

Кастомные команды (Bold/Italic/Font size) передаются через `@FocusedValue(\.formatActions)`. Стандартные команды (Cut/Copy/Paste/Undo/Redo) — через `NSApp.sendAction` → responder chain.

### Feedback loop prevention

В `updateNSView` флаг `isInternalUpdate` предотвращает цикл: textDidChange → document.content = … → SwiftUI вызывает updateNSView → НЕ перезаписываем textView.string.

### updateNSView: смена темы требует явной обработки

`coordinator.parent = self` обновляет `parent.theme`, но **не** обновляет `textView.theme` и не вызывает `rehighlight()`. Без явной проверки переключение тем визуально не работает. Паттерн: сравнивать по `theme.name` (т.к. `NSColor` не `Equatable`), затем обновлять textView и rehighlight:

```swift
if textView.theme.name != theme.name {
    textView.theme = theme
    textView.textContainerInset = NSSize(width: theme.editorInsetH, height: theme.editorInsetV)
    coordinator.rehighlight()
    return
}
```

`EditorTheme` содержит поле `var name: String` — идентификатор темы (“system”, “comfortable”, “github”).

## Known Issues / Gotchas

### ReferenceFileDocument.init(configuration:) — nonisolated

Protocol methods `init(configuration:)`, `snapshot()`, `fileWrapper()` — nonisolated. Свойства, мутируемые в них:

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

Closure в `addObserver(forName:object:queue:using:)` — `@Sendable`, конфликт с `@MainActor`. Решение: selector-based `addObserver(self, selector:, name:, object:)`.

### NSTextStorage: комбинирование font traits (bold + italic)

При применении italic к тексту, который уже может быть bold — читать существующий шрифт из storage и union трейты, иначе italic затрёт bold:

```swift
let existing = storage.attribute(.font, at: range.location, effectiveRange: nil)
    as? NSFont ?? fallbackFont
let combined = existing.fontDescriptor.symbolicTraits.union(.italic)
if let font = existing.withSymbolicTraits(combined) {
    storage.addAttribute(.font, value: font, range: range)
}
```

### ImageProvider (MarkdownUI) + Swift 6: не использовать NSImage

`@MainActor struct` не может конформить nonisolated `ImageProvider` в Swift 6 strict mode. Решение: `AsyncImage` с `file://` URL (резолвить путь до файла, отдать URL). `NSImage(contentsOf:)` — @MainActor в macOS 26 SDK, использовать нельзя.

### Кэширование spans: `collectSpans` — чистая функция текста

`collectSpans` зависит только от текста, не от позиции курсора. Coordinator кэширует результат в `cachedSpans` и инвалидирует при `text != cachedText` (String `==` через pointer equality — O(1) для COW). При движении курсора spans берутся из кэша, пересчитывается только `activeRegion` и применяются атрибуты. Аналогично `cachedQuoteDepths` — глубина цитат вычисляется O(N) стеком при изменении текста.

### NSTextBlock не работает при isRichText = false

`NSTextBlock` (border, padding через `NSMutableParagraphStyle.textBlocks`) — не рендерится когда `NSTextView.isRichText = false`. Для рисования левых полос/фона блоков использовать подкласс NSTextView с переопределением `drawBackground(in:)`:

```swift
class MarkdownNSTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // использовать layoutManager.enumerateLineFragments для позиций строк
    }
}
```

### quoteMarker в вложенных blockquote

`cmark_node_get_start_column(node)` даёт колонку `>` для данного уровня вложенности (sc=1 для внешнего, sc=3 для вложенного после `> `). Для поиска маркера на каждой строке: `lineIdx.offset(line, sc)`, НЕ `lineIdx.lineStart(line)`.

### headIndent для вложенных blockquote (NSParagraphStyle — paragraph-level атрибут)

`headIndent` / `firstLineHeadIndent` применяется к **первому символу параграфа** — NSLayoutManager игнорирует стили на последующих символах той же строки. Проблема: внутренний blockquote начинается на колонке 3 (после внешнего `> `), но параграф начинается на колонке 1. Применение `paragraphStyle` только к `quoteBody` range — НЕ работает для вложенных цитат. Решение: расширять range до начала строки перед применением `paragraphStyle`:

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
- `rect.maxY` = нижний визуальный край Для позиционирования overlay в **верхнем** правом углу code block: `y: paddedRect.minY + offset`.

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

`NSLayoutManagerDelegate` не помечен `@MainActor`, но `NSTextView` (и его подклассы) — `@MainActor`. Конформанс вызывает ошибку “crosses into main actor-isolated code”. Решение: `nonisolated` на методе делегата + `MainActor.assumeIsolated` внутри (AppKit гарантирует вызов на главном потоке):

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

Для Undo/Redo — `Selector(("undo:"))` / `Selector(("redo:"))` (с двоеточием), потому что `#selector(UndoManager.undo)` даёт `undo` без `:`, а AppKit ожидает `undo:`.

### SourceKit false positives

При редактировании отдельных файлов SourceKit показывает “Cannot find type X” — это нормально, пока проект не проиндексирован целиком. Проверяй реальные ошибки через `xcodebuild`.

### xcodebuild test: linker error \_\_\_llvm\_profile\_runtime

Unit-test bundle без host app не линкует code coverage runtime. Всегда передавать: `-enableCodeCoverage NO` при вызове `xcodebuild test`.

### cmark C API: позиции узлов (1-based, UTF-8 байты)

`cmark_node_get_start_column` / `cmark_node_get_end_column` — **1-based UTF-8 byte column**. Конвертация в UTF-16 NSRange требует маппинга байтов (см. `LineIndex` в `MarkdownHighlighter.swift`).

Важные особенности по типам узлов:

- `CMARK_NODE_CODE` (inline code) — позиции span **только content** (без backticks). Расширять вручную: `sc - bt` / `offsetAfter(ec) + bt`, где `bt = cmark_node_get_backtick_count(node)`.
- `CMARK_NODE_STRONG`/`EMPH` — позиции включают маркеры (`**` / `*`); тело = весь nodeRange.
- `CMARK_NODE_HEADING` — позиции = вся строка заголовка включая `# `; trailing `\n` НЕ включается в `ec`.
- `CMARK_NODE_LINK` — `cmark_node_first_child` / `cmark_node_last_child` дают диапазон текста внутри `[...]`.
- `CMARK_NODE_CODE_BLOCK` — fenced: `cmark_node_get_fence_info != nil`; indented: fence\_info == nil. Позиции включают fence строки.
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

> `swift-markdown-ui` удалён в v12 — Preview режим убран из приложения. `swift-cmark` (прямая зависимость) удалена в v13 — заменена на `swift-markdown` MarkupWalker.

## Conventions
