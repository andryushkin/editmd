# EditMD — история версий

Полная история релизов v1–v35: что сделано в каждой версии и её gotchas. Вынесена из `CLAUDE.md` (2026-07-10), чтобы держать основной гайд компактным. В `CLAUDE.md` остались Overview, краткая карта версий, сводка ключевых инвариантов и вечные gotchas; здесь — первоисточник. Перед работой над областью, которую строила конкретная версия (таблицы, wiki-links, frontmatter, git-интеграция…), читай её раздел.

## Roadmap трёх режимов (принят 2026-07-06)

- **v18 ✅** — каркас режимов + plain Source + Preview (WKWebView)
- **v19 ✅** — линтер в Source (14 правил, temporary attributes, quick-fix в контекстном меню, счётчик в статус-строке)
- **v20 ✅** — WYSIWYG-фундамент: рендерер `MarkdownToAttributed` + сериализатор `AttributedToMarkdown`, round-trip ворота зелёные
- **v21 ✅** — Visual = настоящий WYSIWYG: `VisualTextView.swift` (isRichText, семантика ввода, декорации, острова read-only)
- **v22 ✅** — таблицы NSTextTable (редактируемые ячейки, Tab/Enter-навигация), картинки NSTextAttachment, курсор/скролл сохраняются между режимами (EditorPositionStore)
- **v23 ✅** — чистка (гибрид v17 удалён, Source = SourceTextView) + ⌘K ссылки в Visual + visual-audit.md переписан. **Roadmap трёх режимов завершён.**
- **v24 ✅** — сайдбар-оглавление + сплит редактор/превью + тулбар в стиле agterm (паттерны из github.com/umputun/agterm)
- **v25 ✅** — паттерны из FSNotes (github.com/glushchenko/fsnotes): интерактивный Preview (Enter→Visual, кликабельные чекбоксы с записью в исходник, CSS синхронизирован с редактором), Back/Forward по документам, Edit▸Find (⌘F/⌥⌘F/⌘G/⇧⌘G/⌘E через NSTextFinder), полное Format-меню (strikethrough/code span/заголовки ⌥⌘1–6/списки/цитата/code block — в Source и Visual)
- **v26 ✅** — Settings-окно (⌘,): шрифт/отступы/ширина колонки раздельно по Source/Visual/Preview, межстрочный интервал (Visual), line-height (Preview), тема + цвета элементов (General). `EditorFontSettings` удалён в пользу `EditorSettings`
- **v27 ✅** — настройки по-настоящему применяются + per-mode элементы: честные цвета (Visual/Preview/Source читают тему, не хардкод), выбор гарнитуры+веса per mode, per-mode ElementStyles (H1–H6/bold/code/link/quote — размер/вес/цвет), **Source получил подсветку** (стилизует raw markdown по своим элементам), Appearance (System/Light/Dark) персистится, Comfortable удалён
- **v28 ✅** — **уход от `DocumentGroup` → `WindowGroup` + `DocumentRegistry`**; файловый сайдбар (несколько workspace: скрытые/пины/loose; вкладки Files/Outline), Lite mode (Finder→отдельное окно), модалка «файл уже открыт в другом окне», on-focus reload. См. «## v28 — Complete» ниже
- **v29 ✅** — **большие файлы больше не вешают приложение** (файл-таблица 342K/9000 ячеек висел ∞ на 100% CPU): `MDBlock` стал `Hashable` с ручным O(1) `hash(into:)` (не хеширует payload `.raw`), большие таблицы (>400 ячеек) рендерятся моноширинным island’ом вместо `NSTextTable`, `allowsNonContiguousLayout`, Source пропускает подсветку/линт на «тяжёлых» документах. **Дерево подпапок** в сайдбаре (ленивое, раскрытие персистится). См. «## v29 — Complete» ниже
- **v30 ✅** — **wiki-links `[[Note|alias]]`** во всех трёх режимах (Obsidian-стиль): сканер `WikiLink.swift` (`originalInner` = источник истины для round-trip), подсветка Source, `.mdWikiLink`-атрибут + сериализация Visual, HTML+JS Preview; навигация `WikiLinkResolver` (ленивый actor-индекс basename→\[URL\], Cmd+click/клик открывают файл). См. «## v30 — Complete» ниже
- **v31 ✅** — **большие таблицы рисуются как таблицы в Visual** (был моноширинный island с v29): чистый `parseGFMTable` + виртуализированная отрисовка сетки в `drawBackground` (только видимые строки, read-only). См. «## v31 — Complete» ниже
- **v32 ✅** — **виртуальное выравнивание колонок таблиц в Source** (`.kern`, файл не меняется): `scanSourceTables` + kern-паддинг до целевой ширины колонки с капом (длинная ячейка → рваная строка). См. «## v32 — Complete» ниже
- **v33 ✅** — \*\*YAML frontmatter «как в Obsidian» (Visual + Preview) + подсветка ``yaml во всех трёх режимах**: `Editor/Frontmatter.swift` (детект блока `---…---`, разбор свойств, YAML-токенайзер). swift-markdown frontmatter не знает (открывающий `---` = thematic break, закрывающий после тела = setext H2 → блок раздувался в заголовок). Frontmatter: Visual — read-only остров-карточка свойств (round-trip дословный через `.raw`), Preview — таблица свойств, **Source** — YAML-подсветка тела + приглушённые `---`-фенсы (перекрывает setext-mangle). ``yaml код-блоки — подсветка ключ/значение в Preview (HTML-спаны) и Source (`.codeBlockBody(language:)`), Visual остаётся моно. См. «## v33 — Complete» ниже
- **v34 ✅** — **внешние правки открытого файла + GitHub-style diff** (app **0.34.3** = v34.1 gutter + v34.2 detect-commit + v34.3 commit/push): `DocumentRegistry` watch (`DispatchSource` + app-activate), clean → auto-reload + banner review, dirty → conflict (Keep Mine / Take Disk); unified diff sheet (NSTextView, Source-подсветка, wide). См. «## v34 — Complete» ниже
- **v35 ✅** — **вкладка Git в сайдбаре** (app **0.35.1** = 0.35.0 tab + 0.35.1 perf): Commit/Push/Diff перенесены из status bar; workspace-scoped porcelain (только md внутри adopted folders); status bar = info (`branch · +N −M · ↑ahead`); unified diff sheet переиспользуется для HEAD→buffer/worktree. См. «## v35 — Complete» ниже

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
- **O(N) quote depth** — стек `NSMaxRange` значений вместо O(N²) containment loop; использует depth-first порядок cmark (outer BLOCK\_QUOTE → ENTER раньше inner)
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
- **visual-audit.md** — все 17 SpanKind помечены \[x\]; 3 пункта light/dark/selection требуют ручной проверки

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

`visitInlineCode` (SpanCollector) emits три span’а:

```swift
// bt = (r.length - inlineCode.code.utf16.count) / 2
let openRange  = NSRange(location: r.location, length: bt)             // codeMarker
let bodyRange  = NSRange(location: r.location + bt, length: bodyLen)   // code
let closeRange = NSRange(location: NSMaxRange(r) - bt, length: bt)     // codeMarker
```

`code` span (тело) получает: monospaced font + `inlineCodeBackground` + `inlineCodeColor`. `codeMarker` (backtick-и) получает: `applyMarker(secondary)` — скрывается когда курсор не на строке.

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

**SourceRange — exclusive upperBound:** swift-markdown добавляет `+1` к cmark’s endColumn. Для конвертации в NSRange — `lineIdx.offset()` для обоих bounds (НЕ `offsetAfter` для upperBound):

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

### v27 — Complete (настройки применяются по-настоящему + per-mode элементы + подсветка Source)

- **Модель переписана** — `EditorSettings` теперь несёт: `general` (themePreset + `AppearanceMode` system/light/dark + textColor/accentColor hex-оверрайды), три `ModeSettings` (source/visual/preview), у каждого `fontSize`/`insetH`/`insetV`/`columnWidth`/`fontFamily`/`fontWeight` + **свой `ElementStyles`**. `ElementStyle` = {colorHex?, weight: FontWeight?, sizeScale}. Все структуры с кастомным `init(from:)` через `decodeIfPresent` — старые v26-блобы декодятся без потерь
- **Честные цвета (главный фикс v26-обмана)** — раньше ColorPicker крутился, а Visual/Preview хардкодили `NSColor.linkColor`/`.systemOrange`/CSS `LinkText`. Теперь: `EditorSettings.effectiveTheme` = preset + General-оверрайды; Visual `applyDerivedInlineDecorations` красит из `theme` + `visual.elements`; Preview генерит CSS из `preview.elements` + оверрайдов; Source — из `source.elements`
- **Source больше не plain** — `SourceTextView` стал `isRichText=true`; `highlightSource()` применяет РЕАЛЬНЫЕ text-storage атрибуты (не temporary — иначе размер заголовка не меняется) из `collectSpans` + `source.elements`. Два прохода: block (heading-строка целиком с `# ` → размер/вес/цвет; quote) → inline (bold/code/link/italic/strike), чтобы inline перекрывал. Плоская `.string` (source of truth) не трогается, undo чист (attribute-only). Paste → `pasteAsPlainText`. **Частично отменяет решение v23 «Source = plain»** — по прямому запросу пользователя настраивать элементы в каждом режиме
- **Шрифты per mode** — `ModeSettings.resolvedFont(defaultMono:)` строит NSFont из family (пусто = system) + weight через `NSFontDescriptor` weight-trait; `VisualStyle` получил `bodyFamily`/`bodyWeight`/`elements`; Preview — CSS `font: <weight> <size>px/<lh> <family>`. `FontCatalog` (кешированные `allFamilies`/`monospacedFamilies` — enumerate дорогой, набор стабилен за запуск; Source-пикер = только fixed-pitch)
- **effectiveTheme + smena** — тема теперь derived от настроек (computed в ContentView), тулбар-меню тем и Settings пишут один `general.themePreset`. Смена ТОЛЬКО цвета-оверрайда не меняет имя пресета → `updateNSView` name-gate её не поймал бы; поэтому координаторы обновляют `textView.theme = EditorSettings.shared.effectiveTheme` прямо в `settingsDidChange`
- **Дебаунс уведомления** — `.editorFontSizeDidChange` → `.editorSettingsDidChange`; `persist` коалесит пост через `Task.sleep(120мс)` (перерисовка Visual на каждый тик слайдера дорогая); UserDefaults пишется сразу, SwiftUI-биндинги (@Published) обновляются мгновенно
- **Appearance** — `general.appearance` (`AppearanceMode`) вместо `@State isDark`; `ContentView.preferredColorScheme(appearance.colorScheme)` (system → nil); тулбар ☀/🌙 пишет в настройки, резолвит `.system` через `NSApp.effectiveAppearance`
- **SettingsView** — TabView General/Source/Visual/Preview (общей вкладки Elements НЕТ — элементы внутри каждой вкладки режима). Контролы: `FontSizeStepper` (поле+степпер, не слайдер), `ValueSlider` (отступы/колонка/scale/lh), `FontFamilyPicker`, weight-пикеры, `ColorOverrideRow`/`ElementRow` (nil hex = fallback-цвет темы, кнопка сброса), живой `StyleSample` в каждой вкладке. Per-tab reset + глобальный
- **Comfortable удалён** — отличался только insets (теперь per-mode) → был пустышкой; `preset(named:)` маппит старое “comfortable” на System. Мёртвые Typography/Spacing-поля `EditorTheme` пока оставлены (не мешают)
- **243 теста** — +3 previewHTMLPage (font weight/family, heading element CSS, color overrides); Source-подсветка и UI-слой не покрыты юнитами (проверка вживую)

### v27 — gotchas

- **Source-подсветка: только РЕАЛЬНЫЕ атрибуты, не temporary** — `layoutManager.addTemporaryAttribute(.font)` НЕ меняет размер (temporary-атрибуты не влияют на layout). Для смены размера заголовка нужен `textStorage.addAttribute(.font)` → отсюда `isRichText=true`. Линт-подчёркивания (temporary) сосуществуют — разные подсистемы
- **Heading-строка целиком** — `.headingBody(level)` не покрывает `# `-маркер; чтобы вся строка была одного размера — стилизуем `nsText.lineRange(for:)`, а не span. Inline-проход идёт вторым и перекрывает bold/code внутри заголовка
- **`setAttributes` на всю строку сбрасывает подсветку линта?** Нет — линт держит подчёркивания в layoutManager (temporary), `storage.setAttributes` их не трогает
- **Attribute-only мутации внутри `textDidChange` не рекурсят** — `textDidChange` шлётся на изменение символов, не атрибутов; `highlightSource` (begin/endEditing + addAttribute) не вызывает повторный `textDidChange`
- **ColorPicker к optional hex** — `Binding<Color>`: get = `hex → NSColor` или fallback темы, set = `NSColor.hexString`; сброс = `hex = nil`. Сравнение через hex, не NSColor (не Equatable)

### v26 — Complete (Settings-окно: шрифт/отступы/колонка/цвета по режимам)

- **`EditorSettings.swift`** — заменяет `EditorFontSettings` (удалён). `ObservableObject`-синглтон (`.shared`), персист в UserDefaults через `Codable` JSON-блобы (не отдельные `@AppStorage`-ключи — проще версионировать структуру целиком). Каждое изменение поля шлёт `.editorSettingsDidChange` (было `.editorFontSizeDidChange`) — AppKit-координаторы Source/Visual/Preview остаются на notification-паттерне, SwiftUI (`SettingsView`) — на `@Published`
- **`ModeSettings`** (`fontSize`/`insetH`/`insetV`/`columnWidth`) — раздельно для `source`/`visual`/`preview`; `EditorSettings.shared.visual.fontSize` больше не завязан на Source (раньше Visual брал `sharedFontSize + 1`)
- **`columnWidth == 0`** = full width. `ModeSettings.textContainerInset(forWidth:)` считает доп. горизонтальный inset так, чтобы центрировать колонку заданной ширины: `extra = max(0, (viewWidth - insetH*2 - columnWidth) / 2)`. Source/Visual зовут это в `updateNSView` от `scrollView.contentView.bounds.width` — **не в `makeNSView`** (там ширина ещё 0); центрирование “на живую” при ресайзе окна работает благодаря тому, что `ContentView`‘s `GeometryReader` перевызывает body при смене `geo.size`, а SwiftUI зовёт `updateNSView` на каждый такой ре-рендер родителя (не только когда сам representable’s props изменились)
- **`VisualSpacingSettings.scale`** — множитель на хардкод-константы `applyPresentation` (было `style.paragraphSpacing = 6` и т.п. — эти числа НЕ были производными от `EditorTheme`, тема их не трогала вообще; теперь `6 * spacingScale`)
- **Preview** — `previewHTMLPage` получил `lineHeight`/`columnWidth` параметры; `columnWidth > 0` → `max-width: Npx; margin: 0 auto` (центрирует); `columnWidth == 0` (дефолт функции, не дефолт приложения) → `max-width: none; margin: 0`, сохраняя старое поведение “паддинг слева = editor inset, без прыжка при переключении режимов”
- **`GeneralSettings`** — `themePreset` (system/comfortable/github) + опциональные hex-оверрайды (text/accent/code/image). `EditorTheme.preset(named:)` + `.applyingOverrides(_:)` строят итоговую тему; `ContentView.theme` стал computed property от `editorSettings.general`, а не рассинхронизированный `@State` — тулбар-меню тем и Settings-вкладка General пишут в один источник
- **Удалены `editorInsetH`/`editorInsetV`** из `EditorTheme` — были единственным местом, где тема управляла отступами; теперь отступы всегда из `EditorSettings`, независимо от пресета
- **⌘=/⌘−** — раньше меняли один общий `EditorFontSettings.shared.fontSize`; теперь `EditorSettings.shared.adjustFontSize(\.source, by:)` / `\.visual`, каждый режим публикует свой `FormatActions` с собственным keypath — само разделение “per-mode” потребовало только `ReferenceWritableKeyPath<EditorSettings, ModeSettings>` (не `WritableKeyPath` — на классе `self[keyPath:]=` через простой `WritableKeyPath` не компилируется, нужен reference-вариант)
- **Settings-сцена** — `Settings { SettingsView() }` в `EditMDApp.swift`, стандартный ⌘,/EditMD▸Settings… без ручной проводки меню
- **240 тестов** — без изменений (все правки в UI-слое и AppKit-координаторах, не в чистых функциях)

### v25 — Complete (паттерны FSNotes: интерактивный Preview + меню)

- **Enter в Preview → Visual** — `PreviewWebView` (сабкласс WKWebView, `MarkdownPreviewView.swift`): `keyDown` перехватывает Return/Enter (keyCode 36/76) и зовёт `onRequestEdit` (ContentView передаёт только в полноэкранном Preview, в сплите nil). После рендера в полном Preview webview получает фокус async (`makeFirstResponder`), иначе Enter не доходит
- **Кликабельные чекбоксы в Preview** — паттерн FSNotes HandlerCheckbox: JS в `previewHTMLPage` снимает `disabled` и шлёт индекс чекбокса в `messageHandlers.taskToggle`; `TaskToggleHandler` (weak coordinator — WKUserContentController держит хендлеры strongly) → `toggleTaskListItem(in:index:)` (pure, `FormattingHelpers.swift`, по `.taskListMarker`-спанам collectSpans) → `document.content`. Порядок DOM `li.task > input` = порядок спанов (оба — обход дерева документа). Body-фрагмент по-прежнему рендерит `disabled` — RoundTrip/HTML-тесты не задеты
- **CSS Preview = редактор** — `previewHTMLPage(markdown:fontSize:insetH:)`: точный размер шрифта редактора (был +2px), `padding` слева/справа = `theme.editorInsetH`, `margin: 0` (не центр) — переключение режимов не сдвигает текст. Смена шрифта (⌘=/⌘−) ре-рендерит превью через observer `.editorFontSizeDidChange` → `coordinator.rerender` (контент не меняется — без observer CSS остался бы старым)
- **Back/Forward по документам** — `DocumentHistory` (singleton ObservableObject, `Views/DocumentHistory.swift`): слушает `NSWindow.didBecomeKeyNotification`, пишет `representedURL` (DocumentGroup его ставит; untitled без URL не в истории); навигация активирует окно с этим URL или реоткрывает через `@Environment(\.openDocument)`. Меню View: Back ⌘\[ / Forward ⌘\]. Повторный фокус текущей записи не пишется (это же гасит и «эхо» самой навигации)
- **Edit ▸ Find** — `usesFindBar + isIncrementalSearchingEnabled` на обоих NSTextView; меню шлёт `performTextFinderAction` c NSMenuItem-сендером, у которого `tag = NSTextFinder.Action.rawValue` (Find ⌘F, Replace ⌥⌘F, Next ⌘G, Prev ⇧⌘G, Use Selection ⌘E). В Preview — noop (нет NSTextView)
- **Format-меню целиком** — новые опциональные поля `FormatActions`: strikethrough ⇧⌘X, code span ⇧⌘C, заголовки ⌥⌘1–6 (⌘1–3 заняты режимами), bulleted ⌘L / numbered ⌥⌘L / checklist ⇧⌘L, quote ⇧⌘U, code block ⌥⌘C. Source — pure-хелперы `transformLines(_:lines:)` + `fenceLines` (toggle-семантика: если все строки уже в форме — снять); Visual — `toggleInlineStyle(.strike/.code)`, `toggleListKind` (обобщение toggleChecklist), `setHeading`, `toggleQuote` (quoteDepth/quoteGroup), `toggleCodeBlock` (одна группа → сериализатор склеивает в один fence). `selectedParagraphs()` пропускает tableCell/raw — restamp их бы поломал
- **240 тестов** — +15 `TransformLinesTests`, +5 `ToggleTaskListItemTests`

### v25 — gotchas

- **`performTextFinderAction` читает action из sender.tag** — из SwiftUI-кнопки прокидывать NSMenuItem с `tag = action.rawValue` как `from:` в `NSApp.sendAction`
- **WKUserContentController удерживает message handlers strongly** — хендлер держит coordinator weak, иначе retain cycle (webView → controller → handler → coordinator → webView)
- **WKWebView получает keyDown только как firstResponder** — после переключения в Preview фокус надо отдать явно (async, окна ещё нет в makeNSView)
- **Клик по чекбоксу в Preview НЕ требует ре-рендера DOM** — браузер уже перерисовал; дебаунс-reload после `document.content = toggled` визуально no-op, скролл сохраняется штатным pendingScrollY-механизмом

### v24 — Complete (сайдбар + сплит + agterm-тулбар)

- **Сайдбар-оглавление** — `MarkdownOutline.swift` (pure `markdownOutline(text) -> [OutlineItem]`: level/plainText-title/UTF-16 offset через MarkupWalker + LineIndex) + `OutlineSidebar.swift` (SwiftUI, дебаунс-парсинг через `.task(id: content)` 200мс, hover-wash, отступ по level). Клик → `EditorPositionStore.requestJump(toMarkdownOffset:)`
- **Jump-механика** — `.editMDJumpToOffset` нотификация, **object-scoped к positionStore** (один на окно — прыжок не пересекает окна; паттерн agterm). Коордиаторы: Source — setSelectedRange напрямую; Visual — `restoreCursor()` (маппинг через paragraphRanges); Preview — пропорциональный скролл JS
- **Кастомный сплит вместо NavigationSplitView** (паттерн agterm): `HStack(spacing:0)` + divider = Rectangle 1px + невидимая hit-полоса 12px; drag по **абсолютному X** (`DragGesture(coordinateSpace:)`), не translation (feeds back → мерцание); `.zIndex(1)` на divider — иначе правая колонка перекрывает половину hit-зоны; `.animation(value:)` на контейнере — все триггеры анимируются одинаково
- **Сплит редактор+превью** (⌥⌘P) — GeometryReader + HStack: editorPane `frame(width: geo.width * splitFraction)` + divider (fraction = x/width, clamp 0.25…0.75) + MarkdownPreviewView. **editorPane всегда первый ребёнок HStack** (сплит только добавляет siblings) — structural identity сохраняется, NSTextView не пересоздаётся при toggle
- **Preview live-режим** — дебаунс 250мс через `renderTask: Task` (отмена при каждом updateNSView); при живом reload скролл сохраняется попиксельно: `evaluateJavaScript("window.scrollY")` до `loadHTMLString`, restore в didFinish; пропорциональный скролл — только первый рендер
- **`MarkdownDocument.content` didSet → objectWillChange.send()** — сайдбар/live-превью/Preview-статусбар обновляются на каждую правку (init присваивания didSet не триггерят; guard `content != oldValue`)
- **Тулбар в стиле agterm** — плоские `Label` + `.help("… (⌘N)")`; режимы = 3 кнопки с multi-state SF Symbols (`activeSystemImage` — filled при активном + accent tint); split-кнопка `rectangle.split.2x1`/`.fill`; sidebar toggle `sidebar.left`
- **View-меню** — Toggle Sidebar ⌃⌘S, Show/Hide Preview Pane ⌥⌘P через новые FocusedValues (`sidebarVisible`, `splitPreview`); `splitBinding` setter при включении сплита из Preview-режима переключает в Visual
- **Персист** — @AppStorage: sidebarVisible/sidebarWidth (150…400), splitPreview/splitFraction
- **220 тестов** — +9 `MarkdownOutlineTests` (plainText сохраняет backticks инлайн-кода — это ожидаемо)

### v24 — gotchas

- **WKNavigationDelegate `decidePolicyFor` с closure-сигнатурой БОЛЬШЕ НЕ матчится** в macOS 26 SDK (completion стал `@MainActor @Sendable`) — компилятор даёт только warning «nearly matches», метод молча не вызывается, клики по ссылкам уходят в сам WKWebView. Использовать **async-вариант**: `func webView(_:decidePolicyFor:) async -> WKNavigationActionPolicy`
- **`evaluateJavaScript` completion в macOS 26 SDK — @MainActor** — можно писать в @MainActor-состояние координатора без обвязки
- **Jump-нотификация регистрируется только при `positionStore != nil`** — `object: nil` подписал бы координатор на прыжки ВСЕХ окон

### v23 — Complete (чистка + ⌘K)

- **Гибрид v17 удалён** — `MarkdownTextView.swift` (1180 строк) заменён на `SourceTextView.swift` (\~330): plain-редактор + линт + позиция курсора. Умерли: applyHighlighting, activeRegion, инкрементальная переразметка, overlay-кнопки кода, drawBackground-декорации, `spanDiffDirtyRange` (+5 его тестов)
- **`MarkdownHighlighter.swift` живёт** — `collectSpans` + `LineIndex` нужны линтеру (v19) и рендереру островов (v20); все 53 span-теста остаются
- **⌘K в Visual** — Add/Edit/Remove Link: NSAlert с полем URL; существующая ссылка под курсором расширяется через `longestEffectiveRange(.mdLink)`; пустое выделение без ссылки — вставка URL как линк-текста; `FormatActions.editLink` (optional, nil в Source)
- **visual-audit.md переписан** — чеклист трёх режимов вместо матрицы SpanKind v10
- **210 тестов** (215 − 5 SpanDiffDirtyRange)

> **Историческая заметка:** разделы ниже про MarkdownTextView / MarkdownNSTextView / applyHighlighting / activeRegion / applyMarker / overlay-кнопки (v2–v17 gotchas) описывают КОД, УДАЛЁННЫЙ в v23. Они сохранены как знание о граблях NSTextView/TextKit — многие паттерны (boundingRect, button pooling, NSLayoutManagerDelegate, shouldChangeText-restamp) переиспользованы в VisualTextView.

### v22 — Complete (таблицы + картинки + курсор между режимами)

- **Таблицы — третья попытка, успешная** — `isRichText=true` разблокировал `NSTextTable`: `MDBlock.Kind.tableCell(row:column:columns:alignment:)`, ячейки одной таблицы делят `group`; render → параграф на ячейку; presentation вешает `NSTextTableBlock` (ОДИН shared NSTextTable на группу — иначе layout разваливается); сериализатор собирает grid и эмитит GFM (нормальная форма `| --- |`, alignment `:--`/`:-:`/`--:` сохраняются)
- **Редактирование ячеек** — текст ячейки редактируется свободно; целостность через shouldChangeTextIn: правка либо внутри текста одной ячейки (без `\n`), либо покрывает ВСЮ таблицу (удаление целиком); Tab/Shift+Tab — по ячейкам (`nextTableCellPosition`, pure); Tab с последней ячейки и Enter на последней строке добавляют строку; Enter на пустой последней строке — удаляет её и выходит под таблицу; Backspace в начале ячейки — прыжок в конец предыдущей (никогда не сливает); программные перестройки (append/delete row) — под флагом `isProgrammaticTableEdit` (обходит guard)
- **Картинки** — `attachImages` в presentation: U+FFFC + `.mdImage` → `NSTextAttachment` (кэш по src — переиспользование объекта, иначе layout-чурн на каждый keystroke); baseDir = папка .md / корень .textbundle; ширина капится 420pt; нет файла/remote → SF Symbol «photo»-плейсхолдер; сериализация не меняется (.mdImage — источник истины)
- **Курсор/скролл между режимами** — `EditorPositionStore` (класс в @State — мутации не дёргают SwiftUI): канонсостояние = UTF-16 offset в markdown; Source — напрямую; Visual — через `serializeAttributedToMarkdownDetailed(...).paragraphRanges` (карта display-параграф → md-диапазон, обновляется при каждой сериализации); Preview — пропорциональный скролл через JS в didFinish; восстановление: setSelectedRange + centerSelectionInVisibleArea + makeFirstResponder (async — окна ещё нет в makeNSView)
- **Фикс островов** — raw извлекается от начала строки (`lineStart`), чтобы многострочные острова не теряли префиксы промежуточных строк
- **215 тестов** — +7 table round-trip, +1 карта параграфов, +5 nextTableCellPosition

### v22 — gotchas

- **`textView.string = …` / `setAttributedString` сбрасывают выделение и СИНХРОННО дёргают `textViewDidChangeSelection`** — если колбек пишет в разделяемое состояние (EditorPositionStore), он затирает его ДО восстановления. Паттерн: прочитать сохранённую позицию в локальную ДО установки текста (+ делегат после), в Visual — флаг `isLoadingDocument` вокруг перезагрузки
- **Маппинг курсора компенсирует markdown-префикс** — `markdownPrefixLength(for:)` (internal в AttributedToMarkdown.swift): display-колонка + длина `"# "`/`"- [x] "`/`"> "` = markdown-колонка
- **NSTextTable требует один shared инстанс на таблицу** — NSTextTableBlock’и разных NSTextTable не соединяются в грид
- **Хедер таблицы жирный — derived** (в applyDerivedInlineDecorations по row==0), НЕ через .mdInline — иначе сериализатор писал бы `| **a** |`
- **Пайпы в ячейках** — escapeInline с escapePipes=true для tableCell; hard break в ячейке → пробел (ячейки однострочные)
- **Вложенные таблицы (в цитатах/списках) остаются островами** — NSTextTable + indent-контексты не смешиваем

### v21 — Complete (Visual = WYSIWYG)

- **`VisualTextView.swift`** — `VisualMarkdownView` (NSViewRepresentable) + `VisualNSTextView` (isRichText=true) + Coordinator; ContentView case .visual переключён с гибрида v17 на него
- **Поток данных** — render при входе/внешнем изменении; каждый textDidChange: autoformat → applyPresentation → **синхронная** сериализация в `document.content` (+trailing `\n`) → сейв и смена режима всегда видят актуальный markdown; `lastSerialized` отличает внешние правки от своих
- **Семантика ввода** (чистые тестируемые хелперы `autoformatKind`/`continuationKind`/`indentedKind`):
    - Enter: в списке продолжает пункт (ordered +1, task → unchecked); на пустом пункте — выход из структуры; в конце заголовка — обычный параграф; ```` ```lang ```` + Enter → пустой code block
    - Tab/Shift+Tab — вложенность пункта 0..5; Backspace в начале пункта — outdent → paragraph
    - Автоформат после пробела: `- `, `* `, `+ `, `[] `, `[x] `, `#×n `, `N. `
    - ⌘B/⌘I — toggle `.mdInline` + шрифт (по runs); ⌘⇧L Checklist (FormatActions.toggleChecklist, optional — nil в Source/старом редакторе)
- **applyPresentation** — производные визуалы за один проход: paragraphStyle (indent по depth/quote, spacing), перенумерация ordered в группе, strikethrough = mdInline.strike ∪ done-task, цвета ссылок/кода; собирает entry-массивы для drawBackground (буллиты, номера, чекбоксы, quote bars, code panels, hr, H1/H2 dividers)
- **Маркеры рисуются, не печатаются** — `markerRect(forParagraph:)` в марджине слева от `firstLineHeadIndent`; клик по чекбоксу → `toggleTaskDone` (restamp атрибута, undo работает)
- **Острова read-only** — `shouldChangeTextIn` запрещает частичные правки `.raw`-параграфов (удалить целиком — можно)
- **Paste = plain text** — `paste()` → `pasteAsPlainText` (внешний rich-контент ломал бы модель)
- **203 теста** — +17 `VisualEditingTests`

### v21 — gotchas

- **Restamp паттерн** — смена MDBlock-атрибута параграфа через `shouldChangeText(in:replacementString: nil)` → addAttribute → `didChangeText()`: undo регистрируется; для пустого параграфа штамп кладётся на его `\n`
- **typingAttributes наследуют кастомные атрибуты** — от символа перед курсором; ссылки надо явно вычищать в `textViewDidChangeSelection`, иначе набор после ссылки продолжает её
- **`isMutating` флаг** — гейтит textDidChange во время своих мутаций (autoformat/restamp/presentation), иначе рекурсия
- **Перенумерация ordered в applyPresentation** — attribute-only вне undo: derived-состояние, пересчитывается каждый проход; сериализация читает номера ПОСЛЕ presentation (порядок в textDidChange важен)
- **Гибрид v17 (`MarkdownTextView`) остаётся** только как Source-редактор (plainMode); его highlighting-код станет мёртвым после чистки v23

### v20 — Complete (модель WYSIWYG, без UI)

- **`MarkdownToAttributed.swift`** — `renderMarkdownToAttributed(md, style:)`: markdown → NSAttributedString **без маркеров**; семантика в кастомных атрибутах: `.mdBlock` (MDBlock: kind + quoteDepth + quoteGroup + group + listIndent, проштампован на весь параграф включая `\n`), `.mdInline` (битмаска bold/italic/strike/code/rawHTML), `.mdLink`, `.mdImage`; шрифты **пропорциональные** (решение зафиксировано), код — моно
- **`AttributedToMarkdown.swift`** — `serializeAttributedToMarkdown(attr)`: читает ТОЛЬКО семантические атрибуты (шрифты/цвета — производные, никогда не источник истины); стек-алгоритм открытия/закрытия inline-маркеров с reopen (корректно `**a [b](u) c**`)
- **Острова** — Table и HTMLBlock → `.raw(текст)`: отображаются моноширинно (переводы строк → U+2028), сериализуются дословно
- **Нормальная форма** (HTML-инвариантна): setext→ATX, reference-ссылки→inline, loose→tight списки, indented→fenced code, `_`→`*`, `+/*`→`-`, soft break→пробел, hard break→`\`-форма, вложенность списков = 4 пробела, `1)`→`1.`
- **Соседние списки одного семейства** — разделитель `<!-- -->` (приём Prettier): blank line их не разделяет после нормализации маркеров; `group` в MDBlock идентифицирует всё ДЕРЕВО списка (вложенные наследуют group родителя)
- **Ворота качества** — `RoundTripTests` (55): stable-фикстуры `f(x)==x`, идемпотентность `f(f(x))==f(x)`, семантика через HTML-отпечаток `markdownHTMLBody` (нормализация: collapse whitespace + strip комментариев)
- **186 тестов** — +55 RoundTripTests (включая корпус `test-all-elements.md` через `#filePath`)

### v20 — gotchas

- **MDBlock (Swift struct) как значение атрибута** — боксится в `_SwiftValue`; чтение `as? MDBlock` работает; на равенство рантайм полагается только внутри параграфа — сериализатор читает атрибут по индексу начала параграфа (для пустого параграфа — по индексу его `\n`, атрибут проштампован и на нём)
- **Картинка внутри ссылки** — image-run обязан нести `.mdLink` и эмититься ПОСЛЕ open/close маркеров, иначе `[![alt](i)](u)` теряет обёртку
- **`escapeLeading` и для пунктов списка** — текст пункта, начинающийся с `-`/`1.`, породил бы вложенный блок при репарсе
- **quoteGroup в правиле tight-склейки списков** — иначе списки из двух РАЗНЫХ blockquote склеивают цитаты
- **GFM autolink после `(`** — `[text](https://…` без `)`: autolink-спан покрывает URL; смотреть покрытие только `[text]`-части (тот же урок, что в линте v19)

### v19 — Complete

- **`MarkdownLint.swift`** — pure `lint(text) -> [LintDiagnostic]`; принцип: сравнение сырого текста с тем, что распарсилось (spans/AST) — «похоже на разметку, но не распарсилось» = диагностика
- **14 правил**: invalidCheckbox (`- [+]` → error, fixes `[x]`/`[ ]`), emptyCheckbox (`[]`), uppercaseCheckbox (`[X]` → warning, fix `x`), checkboxMissingSpace (`[x]done`), listMarkerMissingSpace (`-[ ]`), unpairedBold/Strikethrough/Backtick, emptyLinkDestination (`[t]()`), unresolvedReference (`[a][нет]`), unclosedLink (`[a](url` → fix `)`), headingMissingSpace (`#Заголовок`), unclosedCodeFence (fix закрыть), tableCellCountMismatch
- **Отображение** — `NSLayoutManager.addTemporaryAttribute` (underline dot: красный error / оранжевый warning + toolTip): не трогает NSTextStorage → документ и undo чистые
- **Quick-fix** — `menu(for:)` override в MarkdownNSTextView: заголовок-сообщение (action nil → авто-disabled) + пункты fix’ов; применение через shouldChangeText/didChangeText (undo работает)
- **Статус-бар** — `LintSummary` (errorCount/warningCount/jumpToNext) через callback `onLintUpdate`; бейдж `✕```` ``  N  `` ````⚠```` `` M ``` кликабелен → прыжок к следующей диагностике
- **Дебаунс** — `Task` + `Task.sleep` 300 мс в Coordinator (Task из @MainActor контекста наследует актор — без Sendable-обвязки, в отличие от DispatchWorkItem)
- **131 тест** — +30 `MarkdownLintTests`

### v19 — gotchas (анти-FP гарды линтера)

- **Чекбокс-правила матчат только `[c]` с содержимым ≤1 символа** — `- [Link](url)`, `- [^1]`, `- [ab]` не флагаются по построению регекса
- **`isCovered` (не только excluded) для чекбокс-правил** — `- [x](url)` это ссылка (linkSyntax покрывает `[`), `*[x]* note` это курсив (italicMarker)
- **unclosedLink проверяет покрытие только `[text]`-части** — GFM extended autolink срабатывает на голый URL после `(` и его linkText-спан маскировал бы матч целиком
- **Unpaired-маркеры**: парные `**`/`~~`/`` ` `` становятся marker-спанами → сканируются только occurrences вне marker/excluded ranges; экранированные `\*\*` не матчатся т.к. в raw-тексте между звёздочками стоит backslash
- **Fence внутри blockquote не проверяется на закрытие** — каждая строка несёт `> `-префикс, детект closing-строки давал бы FP
- **codeBlockFence-спаны для незакрытого fence НЕ надёжны** — SpanCollector эмитит closing-спан для последней строки блока даже когда она не fence (при `el > sl`); линт сканирует текст сам

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

`charWidth = baseFont.maximumAdvancement.width` — точно для monospace (редактор использует `NSFont.monospacedSystemFont`). Применять только к **первому параграфу** пункта (`lineRange(for:)`), иначе continuation-параграфы (blank line + indent) тоже получают неверный indent.

Прежнее правило “не применять headIndent” было связано с установкой `firstLineHeadIndent = headIndent = N` — это создавало двойной отступ (стиль + literal пробелы). Паттерн `firstLineHeadIndent = 0` + `headIndent = N` не создаёт двойного отступа.

`textStartCol` передаётся в `listItemBody(textStartCol: Int)` — 1-based column где начинается текст после маркера (`sc + markerLen` в `visitListItem`).

### Скрытие маркеров в списках — NSColor.clear, не tinyFont

Для unordered маркеров (`- `, `* `) на неактивных строках использовать **только** `.foregroundColor = NSColor.clear`. `tinyFont` (0.01pt) уменьшает ширину символа → текст после маркера смещается влево → hanging indent ломается. `NSColor.clear` делает символ прозрачным но сохраняет layout width — glyph занимает то же место.

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

**Подход 1 — Overlay с per-cell NSTextView editing (v13–v14):** TableOverlayView + CellTextView per ячейке + TableOverlayDelegate (CRUD строк/столбцов). Проблемы: stale NSRange после rehighlight, сложный deferred commit, overlay timing при открытии. Reverted.

**Подход 2 — Toggle по позиции курсора:** Cursor вне таблицы → read-only overlay (hitTest → nil), текст скрыт; cursor внутри → plain markdown. Проблема: cmark-gfm расширяет диапазон `tableBody` на следующий параграф без blank line → логика “cursor inside/outside” ломается. Reverted.

**Корень проблемы:** `NSTextTable` не работает при `isRichText = false`. Overlay-подходы упираются в NSRange-десинхронизацию после rehighlight.

**Следующая попытка:** рассматривать только варианты без overlay — либо `isRichText = true` + NSTextTable, либо plain text с минимальной подсветкой.

## v28 — Complete (файловый сайдбар + workspace, уход от DocumentGroup)

Мотив: нужна навигация по файлам с «заменой файла в том же окне», а `DocumentGroup` = окно-на-документ (файл в окне фиксирован). UX-решения прошли Q&A + макет-ревью в smotr (`docs/design/10_workspace_sidebar.html`). Сделано 4 фазами (255 тестов зелёные, +12).

- **Оконная модель.** `Window("main")` (главное workspace-окно, слушает `AppState.currentURL`) + `WindowGroup(for: URL.self)` (lite-окна). `AppDelegate.application(_:open:)` роутит Finder-открытия через `AppState` по `general.liteMode`: off (деф.) → в главное заменой, on → отдельное окно. ПКМ в сайдбаре → «Открыть в отдельном окне». Клик в сайдбаре по файлу, уже открытому в другом окне → модалка «Перейти к нему»/«Открыть здесь».
- **Слой документа.** `DocumentStore.swift`: `parseMarkdownWrapper`/`makeMarkdownWrapper` (общий core сериализации) + `loadMarkdownDocument`/`writeMarkdownDocument` (диск) + `DocumentRegistry` (URL→`MarkdownDocument`, refcount, dirty, debounce-autosave). `MarkdownDocument` делегирует в этот core (паритет по построению).
- **Сайдбар.** `WorkspaceModel` (несколько workspace-папок, скрытые по папкам, пины loose-файлов, session-loose; персист UserDefaults по пути) + `WorkspaceSidebar` (сегмент Files/Outline, глаз показывает скрытые с restore, пины, ПКМ). File▸Open Folder ⇧⌘O.
- **Создание корневой папки (2026-07-15).** Плюс в Files различает `New Folder…` и `Open Folder…`: первый открывает save-style panel, где выбирают родительский каталог и имя ещё не существующей папки, затем создаёт её, добавляет в сайдбар и открывает. Во внешнем UI это «папка»; `Workspace` остаётся внутренним термином для корня Git/Review/integration scope.
- **Имя папки и display name (2026-07-15).** По умолчанию корень показывается как настоящая папка. Пользователь может отдельно задать отображаемое имя EditMD; если оно отличается, карточка папки показывает обе сущности. Из сайдбара и карточки доступны отдельные команды для display name и физического rename. Rename на диске переносит path-keyed state/snapshot/history, но блокируется, пока внутри корня открыт документ: `DocumentRegistry`, undo/autosave и watchers привязаны к прежнему URL.
- **Режим нового файла (2026-07-15).** Файл, созданный из карточки папки, и untitled через File ▸ New открываются в Visual. Обычная навигация по существующим файлам сохраняет выбранный режим, Finder/Dock по-прежнему открывает Preview.
- **Перемещение файлов (2026-07-15).** Файл можно перетащить на корень workspace, подпапку или открытую карточку папки либо вызвать «Переместить…» и выбрать каталог. ⌘-клик переключает отдельные строки, Shift-клик выделяет видимый диапазон от последнего selection anchor; drag или команда на выбранной строке переносит весь набор. Drag transport использует явный `NSItemProvider` с одним JSON payload группы: custom `CodableRepresentation` компилировался, но не импортировался реальным SwiftUI drop session. Batch сначала проверяет все источники, одинаковые basename и существующие destinations, затем выполняет disk moves; ошибка посередине откатывает уже перенесённые файлы, а path-keyed UI state обновляется только после полного успеха. `.review.json` следует за каждым файлом. Открытые Markdown flush-ятся и паркуются в `DocumentRegistry` session cache, main/lite-представления закрываются и после batch восстанавливаются по новым URL с теми же моделями и undo; у активного review сначала дожидаемся FIFO sidecar pipeline. Hidden/loose/pinned, last-active, sidebar snapshot, history, tags и wiki-link index мигрируют для каждого файла. Общий `LongRunningOperationCenter` сразу блокирует ввод, но показывает material-overlay с `ProgressView` только после 250 мс, поэтому быстрые операции не мигают; слой подключён ко всем main/lite/settings roots и поддерживает перекрывающиеся задачи. Относительные markdown-ссылки внутри переносимых документов автоматически не переписываются.
- **Контекст папки (2026-07-15).** Корни и подпапки в Files, карточка открытой папки, её плитки и дерево используют один `FolderContextMenu`: открыть (когда папка ещё не открыта), создать файл/подпапку, скопировать путь и показать в Finder. Для adopted root дополнительно доступны display name, физическое переименование и удаление из сайдбара. Меню файлов на карточке выровнено с сайдбаром: отдельное окно, перенос, hide/unhide, путь и Finder.

### v28 — gotchas

- **Value-based окна: `WindowGroup(for: URL.self)`, не `URL?.self`** — оптионал-значение дало бы двойной опционал в замыкании (`$url: URL?`). Lite-окна всегда титульные; untitled = File▸New в главном (`AppState.currentURL=nil`).
- **`openWindow`/`Window` действия живут только внутри сцены** → `AppState` захватывает `OpenWindowAction` в `MainWindowView.onAppear` (`bindOpenWindow`) и **буферит** открытия, пришедшие до появления сцены (важно для Lite-on холодного старта из Finder).
- **Замена файла на месте = мутация `AppState.currentURL`**; `MainWindowView` вешает `.id(currentURL)` на `FileEditor` → SwiftUI пересоздаёт `DocHost` (release старого, acquire нового) — чистый редактор без stale-undo. Lifecycle реестра завязан на идентичность вью (deinit `DocHost` → `Task { @MainActor in registry.release }`, т.к. deinit nonisolated).
- **`representedURL`/title** ставит `WindowAccessor` (NSViewRepresentable, `DispatchQueue.main.async` до появления window) — SwiftUI-API нет до macOS 15. «Открыт в другом окне?» и Back/Forward определяются по `NSApp.windows`/`representedURL`.
- **On-focus reload.** Фоновое (не key) окно откладывает внешний reload (`pendingExternalReload`) и применяет на `NSWindow.didBecomeKeyNotification` — иначе правка того же файла в другом окне сбрасывала бы курсор. Source сохраняет offset (clamp), Visual — через `restoreCursor()`. Гейт в `updateNSView`: `textView.window?.isKeyWindow ?? true`.
- **`DocumentRegistry` без Combine-подписок** (Swift 6 strict concurrency): dirty/autosave драйвится явно `markDirty(_:)` из `FileEditor` (`onReceive(document.objectWillChange)`); `release` флашит на последнем refcount. Реестр — `@MainActor`, `init()` internal (тесты создают изолированный инстанс).
- **`WorkspaceModel`** персист по пути в UserDefaults (инъекция `defaults` для тестов, `init(defaults:)`); скан **плоский** (не рекурсивный), файл «в» workspace = его родитель == `folderPath`. `[String: Set<String>]` для скрытых Codable-able.
- **File-меню вручную** (DocumentGroup его больше не даёт): New/Open/Open Folder/Save/Save As через `@FocusedValue(\.documentActions)` (публикует `FileEditor`), Save untitled → `NSSavePanel`.

**Известные шероховатости (отложено):** Lite-on холодный старт может показать лишнее пустое главное окно (`Window`-сцена всегда создаётся); Save As для untitled lite-окна не переусыновляет URL (главное — переусыновляет); `ReferenceFileDocument`-конформанс `MarkdownDocument` оставлен, но сцену не питает (можно снять). **Later:** точка «открыт в отдельном окне» в сайдбаре, восстановление окон, недавние папки, per-document режим, drag-reorder/поиск по файлам (дерево подпапок — сделано в v29).

## v29 — Complete (большие файлы не вешают app + дерево подпапок)

Мотив: открытие большого `.md` (репортнутый `wol/pmid.md` — 342K символов / 1826 строк = ОДНА GFM-таблица \~9000 ячеек) вешало приложение на 100% CPU бесконечно. Диагностика — `sample` зависшего процесса (не гадать!). Обнаружены ДВА независимых O(n)-капкана, оба вокруг того, что `MDBlock` кладётся значением в атрибут NSAttributedString и **NSTextStorage хеширует/сравнивает значения атрибутов при фиксации рангов** (`fixAttributesInRange` → `NSAttributeDictionary` → hash). Плюс `NSTextTable` на 9000 ячеек раскладывается весь сразу (super-linear). Подтверждено ресёрчем (Perplexity) + deepseek: паттерн = маленькие таблицы inline `NSTextTable`, большие → island/placeholder (как FSNotes/Obsidian, которые `NSTextTable` вообще не используют).

- **`MDBlock: Hashable` + ручной `hash(into:)` на `Kind`** — синтезированный хеш `.raw(String)` прогонял ВЕСЬ multi-hundred-KB payload при каждом `addAttribute`. Ручной хеш комбинирует только дискриминант (для `.raw` — просто `9`, без payload; `.raw(let s); hasher.combine(s.count)` — тоже НЕЛЬЗЯ: `String.count` = O(n) обход грапхем-кластеров). Островов в документе единицы → коллизии дёшевы, `==` уточняет при редкой коллизии.
- **Большие таблицы → моноширинный island** (`MarkdownToAttributed.renderTable`): >`maxNativeTableCells`(=400) ячеек → `renderIsland(table)` вместо `NSTextTable`-ячеек. Ранний выход по счётчику строк (rows — `Sequence`, не `Collection`: `.count` резолвится в `count(where:)`). Island = один `.raw`-параграф (round-trips verbatim; построчно разбить нельзя — сериализатор ставит `\n\n` между `.raw`).
- **`allowsNonContiguousLayout = true`** на обоих NSTextView (Apple-рекомендация для больших документов).
- **`markdownIsHeavy(_ content)` + `MarkdownDocument.isHeavy`** (кэш, пересчёт в `content.didSet`): >200K символов ИЛИ (40–200K И >300 строк-таблиц). Source на heavy-доке пропускает `collectSpans`-подсветку (276мс/keystroke) и линт (1207мс) → plain, но мгновенно (как FSNotes viewport). Порог **table-aware**, не только размер — крупная проза остаётся с подсветкой.
- **Дерево подпапок** в сайдбаре: `WorkspaceModel.subfolders(in:)` (непосредственные дочерние папки, skip hidden/packages) + `expandedFolders: Set<String>` (персист). `WorkspaceSidebar.SubfolderNode` — рекурсивная вью, контент папки сканируется ТОЛЬКО пока раскрыта (ленивость критична: под `wol` 7010 файлов в 693 подпапках — плоский рекурсивный импорт недопустим). `FileRow` получил `indent` + `.none` trailing (вложенные файлы без hide/pin).

### v29 — gotchas

- **НЕ клади большую строку в атрибут NSAttributedString наивно** — NSTextStorage хеширует И сравнивает значения атрибутов при `fixAttributes`; для тяжёлого значения дай дешёвый `hash(into:)`. Симптом: 100% CPU в `MDBlock.Kind.hash(into:)` под `-[NSAttributeDictionary newWithKey:object:]` (виден в `sample`, НЕ в юнит-замере render — там нет NSTextStorage-фиксации).
- **`String.count` = O(n)** (грапхем-кластеры, `_foreignOpaqueCharacterStride`). В hot-path (хеш, per-keystroke) — не вызывать. `.utf16.count` дешевле.
- **Два независимых порога, разные цели:** `maxNativeTableCells` (island vs нативная ТАБЛИЦА в Visual, по ячейкам) и `markdownIsHeavy` (plain vs подсветка в SOURCE, по размеру+таблицам). Не путать.
- **Диагностика зависания = `sample <pid> 3`**, не догадки: изолированный замер функции (без NSTextView) не воспроизвёл проблему (301мс), а `sample` живого процесса точно показал `hash(into:)` под фиксацией атрибутов.
- Runtime сам предупреждает: `Obj-C -hash invoked on Swift value MDBlock that is Equatable but not Hashable; severe performance problems` — это был первый след.

## v30 — Complete (wiki-links `[[Note|alias]]` во всех трёх режимах + навигация)

Мотив: `.md`-файлы vault полны Obsidian-ссылок `[[target]]`/`[[target|alias]]`/`[[target#heading]]`/`[[target#^block]]`; `swift-markdown` (cmark-gfm) их не знает → был обычный текст. Ресёрч внешней LLM разобран критически (по wiki-links почти верен, но в его парсере алиас после `#` терялся — исправлено). Сделано 5 фазами, 305 тестов зелёные.

- **`Editor/WikiLink.swift`** — чистый сканер: `MDWikiLinkPayload` (`originalInner` = дословный текст внутри `[[...]]`, **ИСТОЧНИК ИСТИНЫ для round-trip**; target/alias/heading/blockID — только для показа/резолва) + `scanWikiLinks(in:) -> [WikiLinkMatch]` (UTF-16 NSRange, однострочно, первый `]]` закрывает) + `parseWikiInner` (порядок ВАЖЕН: сначала split по `|`, потом по `#`/`#^` — иначе `[[N#H|a]]` теряет алиас; `\|` в таблицах = тоже разделитель).
- **Source** — `Span.Kind.wikiLink(payload:)`/`.wikiLinkSyntax`; `SpanCollector.visitText` сканирует ИСХОДНУЮ подстроку узла (не `text.string` — против экранирования); инлайн-код исключён (у `InlineCode` контент — свойство, не `Text`-дети). Линтер: wiki-диапазоны в `excluded`.
- **Visual** — атрибут `.mdWikiLink` (`MDWikiLinkPayload`); рендерер `appendTextWithWikiLinks`; сериализатор эмичет `[[originalInner]]` дословно; Cmd+click (`wikiPayload(at:)` в `mouseDown`) → навигация. Декорация + чистка typingAttributes.
- **Preview** — `<a class="wikilink" data-wiki-target/heading/block>` + CSS `cursor:pointer` + JS-клик → `wikiLinkClick` message handler.
- **`Views/WikiLinkResolver.swift`** — `actor WikiLinkResolver` (ЛЕНИВЫЙ индекс basename→\[URL\]: под `wol` 7010 файлов, НЕ обходить жадно; build по требованию/по workspace-корням, `invalidate()` пересканирует; FSEvents ещё нет) + `navigateToWikiLink(target:from:)` (@MainActor) → `AppState.shared.openInMainWindow`, bias на папку текущего документа (Obsidian shortest-path), несуществующая → `NSSound.beep()`.

**Осталось:** стиль несуществующих ссылок (другой цвет — сейчас выглядят как валидные), heading/block-скролл после открытия (`navigateToWikiLink` игнорирует heading/blockID), опц. `[[`-автокомплит. Тесты: `WikiLinkScannerTests`, `WikiLinkResolverTests` + wiki-кейсы в RoundTrip/MarkdownHTML.

## v31 — Complete (большие таблицы рисуются как таблицы в Visual)

Мотив: v29 ради антифриза заменил большие таблицы (>`maxNativeTableCells`=400 ячеек) на **моноширинный** `.raw`-island — открывалось быстро, но выглядело как pipe-текст, а не таблица. v31 рисует ту же island КАК таблицу, **не трогая модель/сериализацию** (round-trip неизменен). Подход B′ (моя рекомендация, не ресёрча): рисовать сетку самим в `drawBackground` (как буллиты/quote-bars/чекбоксы), виртуализация по dirtyRect, read-only. Остаёмся в TextKit 1.

- **`Editor/MarkdownTableGrid.swift`** — чистый `parseGFMTable(raw) -> TableGrid?` (заголовки/строки/выравнивания; `splitTableRow` разэкранирует `\|`→`|` и `\\`→`\`, дропает border-пайпы но хранит пустые интерьерные ячейки; `nil` для не-таблиц → HTML-острова остаются моно). **Display-only**, сериализацию НЕ питает. 13 тестов.
- **Рендер** (`MarkdownToAttributed.renderTableIsland`) — `.raw(verbatim)` как раньше (сериализатор читает `.raw` → round-trip дословный), но **display-текст без строки-разделителя** `| --- |` (иначе под заголовком пустая полоса). Display косметичен, длина ≠ raw — ок (островов cursor-mapping коарс, сериализация читает `.raw`).
- **Презентация** (`VisualTextView.applyPresentation`, ветка `.raw`) — если `parseGFMTable` успешен: скрыть pipe-текст (`NSColor.clear`), `.byClipping` + фикс. высота строки (min=max lineHeight), ширины колонок по сэмплу (header + первые 60 строк, clamp 44…260) → `tableColumnEdges`; регистрирует `TableIslandEntry`. Иначе — прежний моно-island.
- **Отрисовка** (`VisualNSTextView.drawTableIsland`) — **виртуализация**: берёт origin первого line-fragment острова (`lineFragmentRect(forGlyphAt:)` — дёшево, один фрагмент) и рисует строки арифметически `y = top + row*rowH`, только пересекающие `dirty` (НЕ перебор всех 9000 фрагментов — это и вешало бы). Границы, фон header, вертикали колонок, выравнивание per column. Display-линия 0 = header, 1… = data.
- Маленькие таблицы (≤400) — прежний редактируемый `NSTextTable`. 318 тестов зелёные (+13).

### v31 — gotchas

- **Виртуализация = арифметика, НЕ `enumerateLineFragments` по всему острову** — перебор фрагментов форсирует layout всех 9000 строк = тот же фриз. Нужна фикс. высота строки (`min==maxLineHeight`), тогда `y=top+i*rowH` и origin одного первого фрагмента достаточно.
- **`.byClipping` на параграфе острова обязателен** — иначе длинная ячейка ПЕРЕНОСИТСЯ → фрагментов больше числа строк → арифметика `line i = row i` ломается. U+2028 всегда бьёт строку независимо от lineBreakMode.
- **Display-текст острова косметичен** — можно дропать строку-разделитель и вообще менять, `.raw`-значение (= сериализация) не затрагивается. Отсюда «нет пустой полосы под header» без риска round-trip.
- **Ширины колонок — по сэмплу** (первые 60 строк), не по всем 9000: measure каждой ячейки был бы O(rows·cols). Clamp min/max, чтобы одна длинная ячейка не разнесла грид.
- **Известные ограничения (MVP):** большие таблицы read-only; широкая клипается (нет независимого H-скролла); текст ячейки — сырой inline-markdown (`**bold**` не рендерится). Полноценное решение — на будущее (редактирование + H-скролл), направления в [[editmd-large-tables-future]] / памяти.

## v32 — Complete (виртуальное выравнивание колонок таблиц в Source)

Мотив: в Source (сырой моноширинный markdown) таблицы с ячейками разной длины нечитаемы — пайпы не в столбик. Пользователь хотел «наглядно», но БЕЗ правки файла (vault под git — паддинг пробелами = мусорные диффы). Решение: **виртуальные пробелы через атрибут `.kern`** — байты файла не меняются, колонки визуально выравниваются (как подсветка — display-only). Развилку «широкие колонки → перенос?» решили: в Source перенос НЕВОЗМОЖЕН (plain text, нет display-only `\n`; перенос ячейки = настоящая раскладка = дело Visual-grid), поэтому кап ширины + рваная строка.

- **`scanSourceTables(text) -> [[SourceTableCell]]`** (чистая, в `MarkdownTableGrid.swift`, переиспользует `isTableDelimiterRow`) — находит pipe-таблицы (header с пайпом + `---`-разделитель + body до пустой строки), возвращает ячейки ВСЕХ физических строк (header/delimiter/body). `SourceTableCell` = {column, segmentRange (между пайпами, exclusive), kernIndex (символ под `.kern` = перед закрывающим пайпом; для пустой ячейки — открывающий пайп)}. UTF-16 NSRange — прямо в NSTextStorage. `unescapedPipePositions` пропускает `\|` (backslash → skip next).
- **Применение** (`SourceTextView.highlightSource` Pass C, `applyTableAlignment`) — target ширины колонки = min(max измеренной по ячейкам, cap=40·charWidth); `.kern = target − natural` на kernIndex. **Ширина меряется по УЖЕ стилизованной подстроке** (`storage.attributedSubstring(from:).size()`), поэтому bold/heading-ячейки считаются верно; **эмодзи/CJK** тоже (реальная ширина, не число символов). Кап → длинная ячейка не паддится (kern 0), её строка рваная, остальные держат колонку. Delimiter-строка тоже кернится (пайпы в столбик; после `---` остаётся зазор — приемлемо).
- **`.kern` чистится из `typingAttributes`** в `textViewDidChangeSelection` (иначе набранный после кернутого символа текст унаследует зазор); пересчёт на ре-хайлайте.
- **Heavy-гейт бесплатный** — `applyTableAlignment` внутри `highlightSource` ПОСЛЕ раннего return для тяжёлых доков (гигант-таблица остаётся plain, kern по 9000 строкам не считается).
- 322 теста зелёные (+4 `scanSourceTables`). **Недеструктивно** — проверено: файл на диске байт-в-байт неизменен после открытия.

### v32 — gotchas

- **Виртуальные пробелы = `.kern`, НЕ вставка пробелов** — display-only, файл не пухнет, round-trip не при чём (текст не трогается). Каретка/выделение корректны (NSLayoutManager учитывает kern в раскладке).
- **Перенос ячейки в Source невозможен** — нет display-only line break в TextKit; `.kern` двигает глифы только горизонтально. Wrap широких ячеек → только Visual-grid (там сами рисуем).
- **Мерить ширину ПОСЛЕ passes A/B** (шрифты применены) и ДО добавления kern — иначе bold/heading-ячейки или уже-кернутый текст дадут неверную ширину.
- **`.kern`-значение — `NSNumber(Double)`**, применяется на 1 символ (`kernIndex`), добавляет зазор ПОСЛЕ него (→ сдвигает закрывающий пайп вправо).

## v33 — Complete (YAML frontmatter «как в Obsidian» в Visual + Preview)

Мотив: `.md`-файлы vault (nutriom-карточки и пр.) начинаются с YAML-frontmatter (`---\ntitle: …\ntags: [x]\n---`). swift-markdown (cmark-gfm) frontmatter НЕ знает: открывающий `---` парсится как thematic break, а закрывающий `---` ПОСЛЕ тела — как **setext-заголовок H2**, из-за чего весь блок раздувался в большой заголовок во всех режимах. Итог (после нескольких итераций с пользователем): **Visual + Preview — frontmatter «как в Obsidian»** (панель/таблица свойств); **Source** — frontmatter и \`\`\`yaml подсвечиваются YAML-токенами (изначально «Source оставить как есть», затем пользователь попросил и код-блок, и верхний блок). Frontmatter-РЕНДЕР (остров/таблица) — только Visual+Preview; в Source frontmatter остаётся сырым текстом, но с YAML-подсветкой. 344 теста зелёные (+22).

- **`Editor/Frontmatter.swift`** — чистое ядро (переиспользуется Visual+Preview, НЕ Source):
    - `frontmatterRange(in:) -> FrontmatterRange?` — первая строка ровно `---` + позже закрывающая `---`/`...`; `full` (с фенсами, без trailing `\n`) + `body`. Малформ/без закрытия → nil (старое поведение).
    - `parseFrontmatterProperties(body) -> [FMProperty]` — прагматичный line-based ридер (не полный YAML): scalar / flow-list `[a, b]` / block-list (`- item`), пропуск комментов/пустых. `FMProperty{key, value, items}`.
    - `yamlLineSegments(line) -> [(text, YAMLTokenKind)]` — токенайзер для подсветки; **конкатенация текстов сегментов == строка** (офсеты валидны для NSTextStorage). `.key/.punctuation/.string/.number/.bool/.null/.comment/.plain`. **Plain (сырые нетипизированные скаляры) НЕ красятся** — длинные текстовые значения не пестрят; красятся только кавычки-строки/числа/bool/null/ключи/комменты/пунктуация.
- **Preview** (`MarkdownHTML.swift`) — `markdownHTMLBody` детектит frontmatter, СТРИПАЕТ из markdown перед визитором (иначе mangle), префиксует `frontmatterTableHTML` (Obsidian-таблица свойств: `td.fm-key` приглушённые + `fm-chip`-чипсы для списков). `yaml/`yml код-блоки → `highlightYAMLToHTML` (спаны `.yaml-*` + CSS с dark-media). Порог для CSS — `prefers-color-scheme`, не `light-dark()` (deployment 13.0).
- **Visual** (`MarkdownToAttributed.swift` + `VisualTextView.swift`) — `VisualRenderer.run` эмитит frontmatter как `.raw`-остров (round-trip дословный: `.raw` сериализуется verbatim) и ПРОПУСКАЕТ AST-узлы внутри `full` (их loc \< `NSMaxRange(full)`). **Display-текст острова** = чистые `key: value` строки (фенсы дропнуты — косметика, сериализация читает `.raw`). `applyPresentation` ветка `.raw`: `parseGFMTable` → таблица-остров (v31), иначе `frontmatterRange(rawText) != nil` → карточка свойств (`colorYAMLIsland` красит ключи/значения через `yamlLineSegments`; `propertiesPanelRanges` → скруглённая панель+бордер в `drawBackground`). Read-only (как все острова — правка frontmatter в Source).

### v33 — gotchas

- **Три режима — три независимых парс-пути**: Source=`collectSpans`, Visual=`VisualRenderer`, Preview=`HTMLBodyVisitor`. **Frontmatter-РЕНДЕР** (остров-карточка / HTML-таблица) — только Visual+Preview. В **Source** frontmatter остаётся сырым текстом, но подсвечен: `highlightSource` Pass B.5 детектит `frontmatterRange`, СБРАСЫВАЕТ шрифт всего блока на base (перекрывая setext-heading-mangle из Pass A), красит тело через `highlightYAMLBlock` и приглушает `---`-фенсы. **\`\`\`yaml-подсветка** — Source+Preview: Source красит `.codeBlockBody(language:)` в Pass A + тело frontmatter тем же \`highlightYAMLBlock\` (фенс/\`—\`-строки \`yamlLineSegments\` оставляет \`.plain\` → не красятся; только цвет, моно-шрифт не меняем → выравнивание цело).
- **Round-trip держит `.raw` (полный блок с фенсами), а не display** — display-текст острова косметичен (можно дропать фенсы/чистить), сериализатор берёт `.raw`. Разделитель к след. блоку = `\n\n` (если в оригинале был один `\n` после `---` — нормализуется в пустую строку, приемлемо).
- **Пропуск AST-узлов frontmatter в Visual — по офсету старта** (`lineIdx.offset(child.range.lower) < NSMaxRange(full)`), НЕ по типу узла: setext-heading покрывает тело+закрывающий фенс, оба (thematic break + heading) стартуют внутри `full`.
- **`yamlLineSegments` обязан быть лосслесс** — конкатенация сегментов == строка, иначе офсеты покраски в Visual разъедутся. Есть тест `testSegmentsReconstructLine`.
- **`keyColonIndex`**: разделитель `key: value` = первый `:` вне кавычек, за которым пробел или EOL → `url: http://x` корректно делит после `url` (в `http:` после `:` идёт `/`).
- **Малформ frontmatter** (нет закрытия) → `frontmatterRange` = nil → старое (mangled) поведение; спец-рендер только для well-formed.

**Осталось:** frontmatter в Visual read-only (правка в Source) — редактируемые свойства-виджеты как в Obsidian Live Preview отложены; подсветка \`\`\`yaml в Visual (код-блоки там пока моно — Source+Preview уже есть); nested-map значения показываются плоско (`sub: v; sub2: v2`).

## v34 — Complete (external disk reload + GitHub-style diff) — app **0.34.3**

Мотив: агент/другой app пишет в `.md`, который уже открыт в EditMD — раньше `DocumentRegistry` держал stale buffer (перечитывал только при acquire). Нужен auto-reload + понятный review «что приехало», и conflict path, если есть несохранённые правки. Версия приложения: `CFBundleShortVersionString` **0.34.3**, `CFBundleVersion` **343** (v34.0 reload/diff → v34.1 gutter → v34.2 detect-commit → v34.3 commit/push + suggested messages).

- **Watch + sync** (`DocumentStore.swift` / `DocumentRegistry`):
    - `DispatchSource` (`O_EVTONLY`) на каждый live entry; re-arm после atomic replace.
    - Fallback: `NSApplication.didBecomeActive` → `syncAllOpenFromDisk`.
    - **Clean** buffer: reload content + assets, clear undo, post `ExternalChangeNotice.applied` (before/after + line stats).
    - **Dirty** buffer: **не** clobber; post `.conflict` once per distinct disk payload (`pendingConflictDiskContent`).
    - Session cache: reload с диска только если mtime **новее** known (не затирает unflushed memory).
    - Resolve API: `dismissExternalChange`, `keepMineOverDisk`, `applyExternalContent`, `revertAppliedExternalChange`.
- **Line diff** (`Editor/TextDiff.swift`): pure `lineDiff(before:after:)` / `splitDiffLines` (Myers via `CollectionDifference`), `+added/−removed`.
- **UI** (`Views/ExternalChangeUI.swift` + banner в `ContentView`):
    - Banner над action strip (все режимы): applied (синий) / conflict (оранжевый); **DiffStatsLabel** — зелёный `+N` / красный `-M`.
    - Applied: Diff / Revert / OK; Conflict: Diff / Keep Mine / Take Disk.
    - **UnifiedDiffSheet** (~1200pt min width): read-only `NSTextView`, tight left inset, compact gutters, `+`/`-` + row tint; body = **Source highlighting** через `makeSourceHighlightedString` / `sourceHighlightedLines` (shared free funcs в `SourceTextView.swift`, ElementStyles + theme).
- **Тесты:** `TextDiffTests`, расширенные `DocumentStoreTests` (external reload, dirty keep, session-cache).
- **visual-audit.md** — переписан под v33+ (статус по коду, Known gaps).

### v34 — gotchas

- **Sandbox/xcodegen:** shell deny срабатывает, если в команде явно фигурирует `*.xcodeproj/project.pbxproj`; `xcodegen generate` без этого пути — ок. Новые файлы → write → xcodegen → build (не вшивать в чужие .swift).
- **Clean auto-reload + review, dirty = stop** — не «всегда before-apply». Snapshot `before` нужен до apply, иначе Diff пустой.
- **suppressNextDirty** — external content set не должен запускать autosave как user edit.
- **SwiftUI Text в dual-axis ScrollView** wrap’ает строки (fixedSize/lineLimit ломались / узкое окно) → diff body = **NSTextView**, не LazyVStack+Text.
- **Source highlight shared** — `makeSourceHighlightedString` `@MainActor` (читает `EditorSettings.shared`); table-kern Pass C в diff не гоняется (не нужен).
- **Свой flush** (Keep Mine / autosave) обновляет `knownModDate` + rearm watch, чтобы не принять свою запись за external.

**Осталось / не в v34:** 3-way merge UI; side-by-side diff; hunk-context only (±N around changes); scroll-to-first-change; FSEvents на workspace (wiki index всё ещё lazy, без FS watch).

### v34.1 — Line gutter + session dirty marks

- **`GutterSettings`** (Settings ▸ General ▸ Line gutter): showLineNumbers, highlightChangedLines, showDirtyBulletsWhenNoNumbers, dirtyMarkColorHex.
- **`LineChangeTracker`**: baseline on open / external apply; dirty = insert/replace lines vs baseline (`lineDiff`); session-only (quit clears).
- **Source / Visual**: `LineNumberRulerView` — **source** line numbers (Visual maps via paragraph ranges; blank lines filled in spacing gaps); unified 11pt digits.
- **Preview**: `data-ln` baked into HTML (no separate rail).
- **Status bar**: compact external-change chip (Diff / Revert / …) next to word count.

### v34.2 — Git detect-commit → clear dirty marks ✅

- **`GitCLI`**: path-scoped git (`rev-parse`, `log -1 --format=%H -- path`).
- **`GitCommitWatcher`**: seeds hash on open; on `didBecomeActive` + after document flush re-checks all tracked paths; if hash **changed** → re-anchor session marks (`noteBaseline` with open buffer, else `clearMarks`) + `.lineChangeMarksDidChange`.
- Any commit that touches the path counts (Terminal / other app / hooks) — not only EditMD-made commits.

### v34.3 — Commit this file + Push (stages 4–5) ✅

- **`GitCLI` writes**: `pathStatus` (porcelain), `stage` (`git add -- path`), `commit(file:message:)` (add + `commit -m -- path` only this file), `push`, `currentBranch`, `aheadBehind`, `runDetailed` (stdout/stderr/exit).
- **UI** (`Views/GitUI.swift`): `GitCommitSheet` (message → save → commit → clear/re-anchor marks; then optional Push); `GitPushConfirm` (NSAlert then `git push`, system credential helper / SSH — no passwords in-app); `GitStatusChip` in status bar (v34: branch · status · ↑N · Commit · Push; **v35:** actions moved to Git sidebar, chip is info-only + `+N −M`).
- **File menu**: Commit File… (⌥⌘K), Push… (⇧⌥⌘P) via `DocumentActions.presentCommit/presentPush` from `ContentView`.
- **After commit**: `LineChangeTracker.noteBaseline` + `GitCommitWatcher.noteCommitted` so gutter marks do not return on the next keystroke.
- **Tests**: temp-repo `GitCLITests` (stage+commit, empty message, clean noop, other files untouched).

## v35 — Complete (Git sidebar tab) — app **0.35.1**

Мотив: Commit/Push в status bar теснили инфо; нужен workspace-scoped обзор изменений (как Source Control), не full-repo IDE. Версия: `CFBundleShortVersionString` **0.35.1**, `CFBundleVersion` **351** (0.35.0 feature → 0.35.1 perf).

- **Navigator:** Files | Outline | **Git** (`arrow.triangle.branch`) в `WorkspaceSidebar`.
- **`GitSidebar.swift`:** header (branch · ↑N/↓M · repo path · Refresh · Push); **Changed** = `git status --porcelain` ∩ workspace roots ∩ markdown only; **Open in editor** = open dirty buffers not already listed; per-row **Diff** (`+/-` icon) + **Commit**; empty states (no workspace / no repo / clean). Multi-repo → секция на root.
- **`GitCLI`:** `porcelainStatus` / `parsePorcelainLine` / `headFileContents` / `workingTreeContents` (один status на repo, не per-file).
- **`GitWorkspaceStatus`:** `snapshotAsync` (Process off-main) + `diffSheetContent(for:)` (HEAD → buffer if open else worktree).
- **Status bar:** info-only `GitStatusChip` — branch, **`+N −M`** (lineDiff vs HEAD), ↑ahead/↓behind; клик → sidebar Git. Commit/Push только в sidebar (+ File menu shortcuts).
- **`UnifiedDiffSheet`:** обобщён через `DiffSheetContent` (external change + git sidebar).
- **Тесты:** `GitCLITests` — porcelain parse, workspace md filter, HEAD/worktree contents.

### v35.1 — perf (freeze fix)

- **Typing ≠ full git:** `GitSnapshotRefresh.deltaOnly` обновляет только `+N −M` из **cached HEAD** (`GitHeadContentCache`); `status`/`branch`/`ahead` — только `.full` (open, focus, commit, becomeActive).
- **Process off MainActor:** `Task.detached` для snapshot status bar + `GitWorkspaceStatus.snapshotAsync`.
- **Sidebar:** на `lineChanges.revision` — patch dirty badges **без** `git status`; full porcelain debounce 600 ms.
- **Huge files:** status-bar lineDiff cap ~8k lines (coarse estimate instead of hang).

### v35 — gotchas

- **Только workspace markdown** — loose/outside workspace и `.swift`/прочее не в списке (паритет Files).
- **Commit path-scoped** как v34.3 (`git add` + `commit -- path`); multi-file commit не делаем.
- **Line delta** кэширует `git show HEAD:path`; invalidate на commit / file switch / `gitRepositoryDidChange`.
- **Diff sheet** предпочитает open buffer (в т.ч. unsaved) over disk — совпадает с «что закоммитится после Save».

## v36 — Complete (Claude Code IDE channel) — app **0.36.0**

Мотив: markdown-задачи (правка выделенного, линт-фиксы, суммаризация) хочется отдавать Claude Code, не встраивая чат и не храня API-ключей. Решение — **фаза 1** из `docs/research/claude-code-integration.md`: EditMD прикидывается IDE для CLI. Пользователь держит `claude` в терминале, жмёт `/ide` — Claude видит текущий файл, выделение и workspace, а правки приходят как **diff на подтверждение**. Версия: `CFBundleShortVersionString` **0.36.0**, `CFBundleVersion` **360**.

Новая папка `EditMD/EditMD/Integration/` — слой СБОКУ от редактора: attributed-модель Visual, сериализатор и пороги больших файлов не тронуты.

- **`MCPProtocol.swift`** — JSON-RPC 2.0 кодек: `JSONValue` (int ≠ double, чтобы `id` возвращался тем же типом), `RPCID`, `RPCRequest/RPCMessage/RPCError`, `MCPContent` (обёртка `content[0].text`).
- **`ClaudeIDEServer.swift`** — `actor` поверх `NWListener` + `NWProtocolWebSocket`; bind строго `127.0.0.1` через `requiredLocalEndpoint`, ephemeral-порт; `setClientRequestHandler` отклоняет апгрейд без валидного `x-claude-code-ide-authorization`. Плюс `ClaudeIDERouter`: `initialize` (protocolVersion `2025-03-26`) / `tools/list` / `tools/call` / `ping` / `shutdown`.
- **`IDELockFile.swift`** — `~/.claude/ide/<port>.lock` (0600, каталог 0700), схема дословно из спеки; `authToken` = 16 байт `SecRandomCopyBytes` → 32 hex; stale-cleanup по мёртвому pid (`kill(pid, 0)`).
- **`ClaudeIDETools.swift`** — 12 стандартных tools + `IDEEditorContext` (протокол, чтобы тесты били по фейку). `getDiagnostics` отдаёт наш линтер (14 правил) — Obsidian-плагины возвращают `[]`.
- **`ClaudeIDEBridge.swift`** — `@MainActor` фасад (выделение, active URL, reveal) + `LiveEditorContext` (nonisolated: main-actor hop за состоянием, `Task.detached` за диском).
- **`DiffApprovalController.swift`** — blocking `openDiff` на `CheckedContinuation`; Accept пишет через `DocumentRegistry.applyAgentEdit`.
- **`ClaudeIDEService.swift`** — старт/стоп по настройке, lock-файл, состояние для чипа, notifications `selection_changed` / `at_mentioned`.
- **UI:** `Views/ClaudeIDEUI.swift` — sheet «Claude предлагает изменение: <tab_name>» (Принять/Отклонить) поверх переиспользованного `UnifiedDiffSheet` v34 + чип `sparkles` в статус-баре (серый = слушает, акцентный = подключён). Settings ▸ General — тумблер «Claude Code integration» (default on). Edit ▸ Send to Claude (⌃⌘A) = `at_mentioned`.
- **Тесты (+95):** `MCPProtocolTests` (кодек, id-типы, notification, ошибки), `IDELockFileTests` (схема, права, stale), `ClaudeIDEServerTests` (**настоящий** WS-клиент: auth ок/отказ, счётчик клиентов, notification без ответа), `ClaudeIDEToolsTests` + `IDEPositionMathTests` + `IDERevealRangeTests`, `DiffApprovalControllerTests` (continuation ровно один раз).
- **Smoke:** `EditMD/scripts/ide-smoke/ide_smoke.py` — WS-клиент на stdlib, имитирует `/ide`: discovery → upgrade с токеном (и проверка отказа без него) → `initialize` → `tools/list` → все tools. Страховка от изменений протокола CLI (риск 6.1 спеки). `--open-diff` шлёт блокирующий diff (решение кликает человек).

### v36 — gotchas

- **WS-клиент обязан подключаться по `.url(ws://host:port/)`**, не по `.hostPort`. С host/port Network.framework **не шлёт HTTP-upgrade**: серверный `setClientRequestHandler` молча не вызывается, клиент получает `ECONNABORTED (53)`. Сервер при этом исправен — так был потерян цикл отладки (проверять сначала клиента).
- **`xcodebuild test` запускает app как тест-хост** → `applicationDidFinishLaunching` поднимал реальный listener и писал lock-файл в личный `~/.claude/ide` разработчика. Гард: `ProcessInfo…environment["XCTestConfigurationFilePath"] != nil` (`AppDelegate.isRunningUnitTests`).
- **Тест-хост убивают SIGKILL** → `applicationWillTerminate` не выполняется. Отсюда обязателен stale-cleanup по pid при старте. Проверено вживую: ⌘Q удаляет lock; SIGKILL оставляет; следующий старт подчищает.
- **`Data.write` не задаёт права** — новый файл получает umask (0644). После записи обязателен `setAttributes(.posixPermissions: 0o600)`, иначе токен читаем всем.
- **Accept через `applyAgentEdit`** → для открытого файла идёт в `applyExternalContent`, который **чистит undo-стек**. Правку Claude нельзя откатить через ⌘Z (только Reject до применения). Осознанный компромисс: путь совпадает с external-change и держит инвариант v34 (`knownModDate` + re-arm watch), иначе своя запись вернулась бы conflict-чипом.
- **`Task {}` внутри метода актора наследует его изоляцию** — `self.send(...)` внутри такого Task не требует `await` (компилятор ругается «no async operations occur within await»).
- **Visual → source координаты** идут через paragraph-map v22 (`markdownOffset(atDisplayLocation:)`), оба конца выделения отдельно. Внутри table-island и frontmatter маппинг паграф-гранулярный, не посимвольный. `openFile` с `startText` в Visual ставит только каретку (display-диапазон ≠ source-диапазон); в Source выделяет найденное.
- **`severity` в `getDiagnostics` — имя**, не число VS Code: `"Error"` / `"Warning"` + `code` = имя правила линтера.
- **`workspaceFolders`**: корни `WorkspaceModel`; если workspace не заведён — папка файла в главном окне (иначе `/ide` не сматчит cwd на свежей установке). Файл перезаписывается на лету при смене набора; живое подключение это переживает (риск 6.4 закрыт).
- **Два окна EditMD = два lock-файла.** CLI выбирает по `workspaceFolders` ⊇ cwd; при неоднозначности поведение на его стороне (риск 6.3 остаётся открытым).
- **Повторный `openDiff` с тем же `tab_name`** отклоняет предыдущий (`DIFF_REJECTED`) и показывает новый. Все пути — disconnect, `close_tab`, таймаут 10 мин, Esc — резолвят continuation ровно один раз.

**Осталось / не в v36:** кастомные EditMD-tools (`getOutline`, `resolveWikilink`, …) — фаза 1.5, требует решения по фильтрации `tools/list`; lite-окна как активный редактор; undo для принятой правки Claude; выделение диапазона в Visual при `openFile`.

## v37 — Complete (метки-треды smotr-style) — app **0.37.0**

Мотив: асинхронная ревью-петля автор↔Claude поверх тех же sidecar-меток, что у smotr — EditMD = второй фронтенд. Версия: `CFBundleShortVersionString` **0.37.0**, `CFBundleVersion` **370**. Спека — `docs/research/claude-code-integration.md` §1.2 / §5 фаза 2; план — `docs/plan-claude-code-integration.md` §4.

- **Шаг A — ядро** (`Editor/ReviewMarks.swift`): `ReviewMark` / `ReviewThreadEntry` / `ReviewDocument` в формате smotr; lossless round-trip через `extra`-бэг (`JSONValue`); sidecar IO с optimistic `rev`-guard (merge by id при чужом rev); якоря — порт `_find_anchor` (`prefix+quote` → near-start → global → nil/`needs-rebase`); `applySuggest` pure; id/ts helpers.
- **Шаг B — UI** (`Views/ReviewModel.swift` + `ReviewSidebar.swift`): вкладка Review (бейдж = openCount) рядом с Files/Outline/Git; создание метки из выделения Source/Visual (`ClaudeIDEBridge.reviewSelectionSource` → source-координаты); реплаи/статусы; suggest-карточки «было → станет» с Accept (`DocumentRegistry.applyAgentEdit`) / Reject. Reload sidecar на `didBecomeActive` (Claude/smotr могут писать out-of-band).
- **Шаг C — подсветка якорей** (`Editor/ReviewHighlight.swift`): temporary `backgroundColor` wash в Source (диапазон по raw markdown) и Visual (plainText-поиск `quote` в display). Цвет по типу метки, низкая alpha. Notification `.reviewMarksDidChange` при смене doc/текста. Lint и review не делят toolTip/underline — review трогает только фон.
- **Шаг E — очередь + opt-in агент** (`Editor/ReviewQueue.swift`): ➤ в шапке Review собирает open-метки workspace → `.smotr-queue.json` (`{created, count, marks:[{file, kind, …}]}`, как smotr). Default: команда `cd … && claude -p "/smotr -pr"` в буфер. Settings ▸ General ▸ «Auto-run Claude for Review queue» (default **off**) → `Process` `claude -p "/smotr -pr"` в корне workspace, лог `.smotr-agent.log`, `EDITMD_AGENT_CMD` env-override для тестов. Spawn + disk — `Task.detached`.
- **Шаг F — ворота**: round-trip тесты против smotr-фикстур (html-mark fields, prompts, stages, project fixture `test-all-elements.md.review.json`); bump 0.37.0 / 370; 555 XCTest.

### v37 — gotchas

- **Якоря считаются по СЫРОМУ markdown** (source of truth), не по display Visual. Capture из Visual уже мапит selection → markdown через paragraph-map v22, поэтому quote обычно без `# `/`> `. Подсветка в Visual ищет quote в plain display — если метка создана в Source с маркерами в quote, wash в Visual может не найтись (карточка в сайдбаре и jump в Source остаются).
- **`.fixedSize()` на Menu/Picker в анимированной колонке сайдбара** → layout↔render цикл (main 100% в `ReviewSidebar.body`). Фикс: `Menu` + явный `.frame`, без fixedSize (паттерн Files/Outline).
- **Снимок якоря при «+»** — `CapturedAnchor` в `@State`. Живое выделение при вводе note в TextEditor сбрасывается фокусом → «Поставить» гасло бы без снимка.
- **Preview не даёт selection** — `noteSelection` только Source/Visual; подсказка compose это говорит явно.
- **rev-guard на диске, не HTTP** — EditMD пишет sidecar напрямую; при `disk.rev != baseRev` мержит свои marks by id на disk-state и пишет `diskRev+1` (роль out-of-band writer из спеки smotr).
- **Очередь сканит дерево workspace** (enumerator, skip hidden/`node_modules`/`.git`) — только off-main. Корень = workspace, owning active file, иначе parent файла.
- **Auto-spawn ищет `claude` в PATH + `~/.local/bin` / homebrew** — GUI app часто не видит shell PATH.
- **Track-changes-рендер внутри Visual-текста НЕ в v37** (только wash + карточки) — attributed-модель не трогаем.

**Осталось / не в v37:** track-changes inline (зачёркнутый quote + replacement рядом), фаза 3 `editmdctl` + skill, CRUD меток через MCP-tools, multi-workspace единая очередь.

### v37.1 — Preview-first review

**Решение:** основной режим для меток smotr — **Preview** (чтение + выделение + wash + jump); Source/Visual — вспомогательные (правка markdown / WYSIWYG).

- Preview selection → `ClaudeIDEBridge` (offsets `data-md-lo/hi`, multi-span, text fallback) → Review ▸ +.
- `window.applyReviewMarks` + CSS wash по типам; `window.scrollToMdOffset` для jump из карточки (fraction fallback).
- `latestNonEmpty` в bridge — focus hop на + не съедает якорь (Visual/Preview).

## v38 — Complete (editmdctl + control socket + skill) — app **0.38.0**

Мотив: Claude (и скрипты) должны управлять EditMD **без** `/ide` — open file, mode, marks, status. Паттерн agterm: unix-socket + thin CLI + skill. Версия **0.38.0** / build **380**.

- **`ControlProtocol.swift`** — JSON-lines `{id,cmd,args}` → `{id,ok,data|error}`; `ControlSocket.defaultPath` = `~/Library/Application Support/EditMD/control.sock` (override `EDITMD_CONTROL_SOCK`).
- **`ControlRouter`** (@MainActor): `ping`, `status`, `open` (`--line`/`--heading`), `reveal`, `mode`, `marks.list` / `marks.add`, `diff.show` (buffer vs disk via `lineDiff`).
- **`ControlServer`** — BSD `AF_UNIX` listen; accept off-main; dispatch `main.sync` → router; socket file `0600`.
- **`ControlService`** — start at launch (skipped under XCTest); stop + unlink on terminate.
- **`editmdctl`** — CLI target in `project.yml`; human output or `--json`.
- **`SkillInstaller`** + `Resources/skills/editmd/SKILL.md`; Help ▸ Install Agent Skill… (confirm + diff on update; optional Codex sibling).
- Jump from control: `.editMDControlJump` → `EditorPositionStore.requestJump` in main `ContentView`.
- **Тесты:** `ControlChannelTests` (10) — codec, skill install idempotent, live socket ping/unknown (client off main to avoid deadlock).

### v38 — gotchas

- **Client I/O never on the main thread in-process** — server `main.sync` for router; a main-thread client deadlocks (XCTest must use background client). External `editmdctl` process is fine.
- **Socket file leftover after crash** — unbound on start (unlink); terminate removes it. XCTest does not touch the user path.
- **`editmdctl` on PATH** — not auto-installed; build the `editmdctl` scheme / copy from DerivedData. Skill documents this.
- **`diff.show` ≠ git** — buffer vs on-disk content only.

## v38.1 — Fix series по код-ревью фаз 2–3 — app **0.38.1**

Пять этапов фиксов по результатам ревью (`6f45a46..a4a4923`). Версия **0.38.1** / build **381**.

- **Этап 1 — крашы/зависания:** `SO_NOSIGPIPE` на клиентских fd (отвал клиента убивал app сигналом SIGPIPE); serve() на конкурентной очереди + `SO_RCVTIMEO` 30s (один висящий клиент голодал весь канал); таймауты 10s в `editmdctl`; SkillInstaller — плоский лукап `Resources/SKILL.md` (оба subdirectory-лукапа возвращали nil → Help ▸ Install Agent Skill был мёртв); `queueRoot` — родитель файла раньше чужого workspace; isHeavy-гейт wash в Visual.
- **Этап 2 — целостность меток:** FIFO-пайплайн persist/reload в `ReviewModel` (снапшот в момент исполнения — быстрые пары мутаций теряли/воскрешали метки); синхронный сброс doc при смене файла (метки предыдущего файла утекали в чужой sidecar); `marks.add` отвечает после durable-записи.
- **Этап 3 — control-канал:** `editmdctl` абсолютизирует пути от cwd вызывающего, роутер отвергает относительные; двухфазный `ControlRouter.process` (main-фаза + deferred disk work на сокет-потоке) — `diff.show`/`marks.list`/`status`/чтения в `open`/`reveal` больше не на main; jump без таймеров (`AppState.pendingControlJump`, consume при mount); `marks.list` активного файла ждёт pipeline и читает диск (после `open` отвечал из пустого сброшенного doc).
- **Этап 4 — perf:** общий кэш якорей `ReviewModel.anchors` (один off-main проход, debounce 300ms) — Source/Preview/сайдбар читают словарь вместо O(n×marks)-поисков на каждый кейстрок; `currentText` больше не @Published; Visual hint через paragraph map (raw-hint красил чужой дубль); selection-мапа Visual за 150ms debounce.
- **Этап 5 — точность якорей:** `anchorRange`/`captureAnchor` на UTF-16 + `.literal` (grapheme-склейка на границе prefix/quote сдвигала якорь; `start` теперь в UTF-16 = JS-оффсеты smotr); cleanup (мёртвые `process`/нотификация, containment-приоритет в `scrollToMdOffset`).
- **Тесты:** +11 (ControlChannelTests 13→20, ReviewMarksTests 31→38) — конкурентные клиенты сокета, durable marks.add, гонки persist, UTF-16 якоря.

### v38.1 — gotchas

- **Merge в `ReviewSidecar.save` не выражает удаления** — при гонке с внешним писателем (smotr web / claude) удалённая локально метка может воскреснуть; для локальных мутаций FIFO-пайплайн это исключает. Полный фикс = tombstones, схему smotr не расширяем без согласования.
- **`marks.add`/`marks.list` активного файла блокируют сокет-поток семафором** до `flushPipeline` (bounded 15s) — клиентская очередь конкурентная, другие клиенты не ждут.
- **Старые sidecar'ы с Character-`start`** (созданные EditMD ≤0.38.0 на текстах с эмодзи) — `start` мог дрейфовать; используется только как hint, ladder `prefix+quote` находит якорь.

## Таблицы-спринт (после v38.1) — строки/столбцы по курсору, drag строк, вставка из буфера

Структурные операции над таблицами во всех режимах + конвертация таблиц из буфера обмена.

- **`TableGrid` — структурные операции** (`MarkdownTableGrid.swift`): `insertColumn(at:)`, `deleteColumn(at:)` (пол ≥1 столбца), `moveRow(from:toGap:)` — gap-семантика вставки (0…rows.count), гэпы вокруг самой строки = no-op.
- **Контекстное меню в Visual** (`VisualNSTextView.menu(for:)`): «Строка выше/ниже», «Удалить строку», «Столбец слева/справа», «Удалить столбец» — относительно ячейки под правым кликом; header защищён (нет «выше»/«удалить строку»), последний столбец не удаляется. Работает и для нативных NSTextTable-таблиц (nearest-glyph → `.tableCell` + проверка попадания в фрейм строки), и для island-гридов (`tableCellHit`).
- **Нативные таблицы перестраиваются через grid** (`VisualCoordinatorTable.swift`): диапазон таблицы → `serializeAttributedToMarkdown` → `parseGFMTable` → мутация → рендер → замена диапазона целиком (`isProgrammaticTableEdit` обходит cell-guard в `shouldChangeTextIn`), курсор возвращается в ту же ячейку через `moveCursor(toCell:group:)`. Island-мутации — через существующий `replaceTableIsland` (`.raw` остаётся source of truth).
- **`renderForInsertion(markdown:into:)`** — рендер markdown для вставки со сдвигом group id за пределы существующих в storage: свежий рендер нумерует группы с 1, и коллизия с уже существующей группой склеивала бы соседние same-group таблицы/списки при сериализации. Через него идут все rendered-вставки Visual: paste, «Вставить таблицу 3×3», divider, table rebuild.
- **Drag-перенос строк в Visual**: ручка-грип (6 точек) в левом жёлобе body-строки по hover (tracking area `.mouseMoved` + `.inVisibleRect`); синхронный drag-цикл (`window.nextEvent`) с wash исходной строки и акцентной линией в целевом гэпе; drop → `moveRow`. Header не перетаскивается; нужно ≥2 body-строк. Кэш фреймов `nativeRowFrameCache` (инвалидация: didSet `tableIslandEntries` = каждый presentation pass, + `setFrameSize`).
- **Вставка таблиц из буфера** (`TableClipboard.swift`): HTML (`public.html` от web/Word/Excel) через `XMLDocument(.documentTidyHTML)` — только когда payload table-dominant (вне `<table>` нет значимого текста, сравнение длин без пробелов, допуск 2 символа); TSV (Excel/Numbers plain) — ≥2 непустых строк, каждая с табом, ≥2 колонок. Инлайны ячеек → markdown (b/strong, i/em, code, a, img, del/s, br→пробел), colspan → пустые ячейки, align/text-align → alignment колонок. Пол ≥2 столбцов и для HTML (копия одной ячейки/столбца Excel остаётся текстом). Funnel `markdownTableFromPasteboard(html:plain:)`: html без `<table>` = rich text → TSV не пробуется.
- **Visual paste** — таблица из буфера рендерится настоящей таблицей (до markdown-эвристики); в `codeBlock` конвертация выключена, в `tableCell` paste остаётся plain (ячейки однострочные). **Source paste** — pipe-markdown с паддингом переводов строк; внутри fenced-блока — plain как раньше (fence-parity guard `caretInsideFence`).
- **Контекстное меню в Source** (`SourceNSTextView`): те же 6 операций по `sourceTableContext(in:at:)` — локальный скан вокруг курсора (header по правилу «следующая строка — delimiter», как `scanSourceTables`; колонка = несэкранированные pipe до курсора минус border-pipe); операция = замена всего диапазона таблицы канонической `serializeGFMTable` (переформатирование намеренное).
- **Тулбар/format-strip**: «Добавить строку» теперь вставляет под строкой курсора (было — в конец), «Удалить строку» удаляет строку курсора (header → beep).
- **Тесты:** +34 (`TableEditingTests.swift`, всего 655) — grid-операции, `sourceTableContext` (границы, borderless-строки, прозу с pipe над header), TSV/HTML конверсия (dominance, инлайны, colspan, alignment, эскейп pipe), funnel.

### Таблицы-спринт — gotchas

- **Native rebuild канонизирует таблицу**: `:--` (явный left) → `---` (none) — `TableGrid.Alignment` не различает их; визуально идентично, diff формата намеренный.
- **Delimiter-строка в Source (line 1)**: операции строк задизейблены, столбцов — работают; `bodyIndex` для неё nil, «Строка ниже» вставляет body-строку с индексом 0.
- **Grip-зона** — 22pt слева от левого края таблицы; у island при горизонтальном скролле уезжает вместе с краем (offset > 0 → ручка может скрыться).
- **Hover-хит нативной строки** идёт через nearest-glyph: точка в жёлобе мапится на ближайший глиф строки — попадание подтверждается `zone.contains(point)`, иначе ручка просто не показывается.

## Формулы-спринт (после pdf-спринта) — $…$ / $$…$$ с KaTeX в Preview — app **0.39.0**

Отображение LaTeX-формул: `$inline$` и `$$display$$` через все три режима. Preview — настоящий рендер (KaTeX, офлайн), Source/Visual — подсветка сырого TeX.

- **`MathScan.swift`** — чистый сканер `scanMathSpans(in:)` (UTF-16, NSString): inline `$…$` (opener не перед пробелом, closer не после пробела и не перед цифрой — валютный гард `$20 и $30`), display `$$…$$` (однострочный — где угодно; многострочный — только если `$$` открывает строку и внутри нет `>`-строк, иначе маска сломала бы blockquote). Код пропускается: fenced (```/~~~), indented (4+ пробела вне параграфа), однострочные `` `код` ``. `\$` не открывает/не закрывает.
- **Маскированный парс в Preview** (`maskMathSpansForParsing`): содержимое спанов заменяется U+E000 (PUA) **юнит-в-юнит** — UTF-16-длина и позиции переводов строк сохраняются, поэтому все оффсеты из парса маскированного текста валидны в оригинале (`data-md-lo/hi`, gutter `data-ln`). cmark не видит TeX → `\frac`/`_`/`*`/`\\` не калечатся. Ведущие пробелы строк внутри спана не маскируются (вложенность списков живёт). `LineIndex` строится от **маскированного** текста (колонки cmark = UTF-8 байты того, что он парсил; сентинел 3 байта).
- **`HTMLBodyVisitor`**: `visitText` режет ран на плain-сегменты и сентинел-раны; учёт по счётчику юнитов (`HTMLMathSpan.units`) — первый ран спана эмитит `<span class="math math-inline|math-display" data-md-lo/hi data-md-code="1">TeX</span>`, хвосты (многострочный `$$` разрезан softbreak'ами) поглощаются молча. `data-md-code="1"` = selection-остров (как рендеренный код), wash ревью-меток по `data-md-lo` работает.
- **KaTeX офлайн** (`Resources/katex/` + `KaTeXResources.swift`): katex.min.js 0.16.22 (277KB) + katex.css с woff2-шрифтами как data-URI (367KB, собран из npm-дистрибутива). Страница грузится `loadHTMLString(baseURL: nil)` — внешние файлы недоступны, поэтому всё инлайном, и **только когда формулы есть** (`markdownHTMLRender` → `hasMath`). Рендер-скрипт: `katex.render(textContent, el, {throwOnError:false})` + повторный `alignLineNumberGutter()` после рендера и `document.fonts.ready`. Display-блоки выровнены ПО ЛЕВОМУ краю с отступом 2em (не по центру — просьба пользователя; `.katex-display`-центрирование KaTeX переопределено). Без ассетов — graceful: виден сырой TeX.
- **Source**: `collectSpans` тоже парсит маскированный текст (никаких setext-H1/emphasis внутри TeX) + пост-скан → `.mathBody(display:)` (цвет `els.inlineCode.color ?? theme.inlineCodeColor`) + `.mathMarker` (secondary) — в обоих аппликаторах (Coordinator + `makeSourceHighlightedString`).
- **Visual**: парсит ТОЖЕ маскированный текст (как Preview) — `=`-строка внутри `$$` больше не делает блок setext-H1, `\\`/`\,` не разэскейпливаются. **Формулы РЕНДЕРЯТСЯ** (раунд 3, по просьбе пользователя): SwiftMath 1.7.3 (нативный порт iosMath, SPM) типографит TeX в NSImage → `NSTextAttachment` с базовой линией из `LayoutInfo.descent` (`MathAttachment.swift`); вербатим-источник (`$…$`/`$$…$$`, с реальными `\n`) лежит в атрибуте `.mdMathTex`, сериализатор эмитит его как есть. Однострочные матчи в `appendTextWithWikiLinks` слиты с wiki-матчами; многострочный `$$` перехватывается на уровне блоков (`multilineMathIndex`) — один аттачмент на весь спан, blank-line-осколки пропускаются. TeX, который SwiftMath не разобрал, остаётся тонированным сырым текстом (`.mdMath`, U+2028 для переносов) — тоже вербатим при сериализации. **Редактирование — двойной клик по формуле** → transient NSPopover (`MathEditorPopover.swift`): моно-поле TeX + живое превью, ⌘⏎/OK применяет (undoable replace через shouldChangeText), пустой TeX удаляет формулу, Esc/клик мимо отменяет; guard на staleness (документ изменился, пока попап открыт → beep). Кнопка ∫ в strip вставляет формулу и сразу открывает редактор. В сериализаторе голый U+FFFC без payload (чужой аттачмент из буфера) глотается — не попадает в файл.
- **Тесты:** `MathScanTests` (сканер/гарды/маска/аттачменты, 25 кейсов) + 8 math-кейсов в `MarkdownHTMLTests` + 4 round-trip фикстуры (всего 697).

### Формулы-спринт — gotchas
- **Цвет формулы-картинки запечён при рендере** (`resolvedLabelColor` через effectiveAppearance) — переключение Light/Dark не перекрашивает уже отрисованные аттачменты до ре-рендера документа (смена режима/файла).
- **Copy/paste формул внутри Visual может потерять `.mdMathTex`** (RTFD не переносит кастомные ключи) — сериализатор глотает голый U+FFFC, формула тихо исчезает из markdown; вставлять формулы заново через ∫ или Source.
- **Покрытие TeX у SwiftMath ≠ KaTeX** — что не разобралось, показывается сырым тонированным текстом (и корректно сериализуется); Preview может отрендерить то, что Visual не смог.

- **xcodegen плющит Resources в корень бандла** — `Resources/katex/katex.css` лежит как `Contents/Resources/katex.css`; `KaTeXResources.load` пробует subdirectory и падает на корень.
- **Многострочный `$$` требует: opener открывает строку, closer закрывает строку** (только пробелы вокруг) — контракт «спан = целые строки», на котором держится блочный перехват в Visual.
- **`\$` в Visual теряет эскейп при сериализации**: cmark разэскейпит `\$`→`$` в plain-тексте, а `escapeInline` `$` не эскейпит (иначе валютные `$20` в любом документе получали бы diff-шум) — literal `$x$` после Visual-редактирования может стать формулой. Корнер, признан.
- **Многострочный `$$` в blockquote не поддержан** (сканер отказывает — маска съела бы `>`); однострочные формы работают везде, включая таблицы и заголовки.
- **Сентинел-учёт полагается на документ-порядок** Text-узлов; документ, сам содержащий U+E000, may съесть спан (guard: молча ничего не эмитим, не падаем).

## Встроенные плагины и multi-checkbox (после **0.40.2**)

- **Граница архитектуры:** плагины только встроенные и скомпилированные на Swift. `BuiltInMarkdownPlugin` + `BuiltInPluginRegistry` дают метаданные, document-scoped activation и semantic tokens; загрузки JavaScript, внешних bundle, marketplace и стороннего executable code нет. Это сознательно сохраняет hardened-runtime модель и не вводит отдельный permissions/sandbox/XPC слой.
- **Frontmatter activation:** `editmd.plugins.multi-checkbox.states` — упорядоченный список состояний (`marker`, optional `label`, `icon`, `strikethrough`). `sf:<name>` использует SF Symbols, `emoji:<text>` — emoji. Минимум один уникальный marker; порядок определяет цикл с wrap последнего в первый. Одно-state шаблон показывает иконку, но не получает ложный click target до появления второго состояния.
- **Checkbox ownership:** валидная конфигурация забирает checkbox-семантику всего файла. Описанные `[marker]` становятся multi-checkbox; неописанные core `[ ]`/`[x]`/`[X]` маскируются как literal text, а не остаются вторым двухсостоянийным механизмом. Без frontmatter стандартный GFM task list не меняется.
- **Общий range contract:** `BuiltInPluginSnapshot` хранит UTF-16 ranges оригинального markdown. Для cmark parse копия length-preserving: list token нормализуется в `[ ]`, inline token маскируется U+E001; delayed Preview click перед заменой повторно сверяет offset/source. Frontmatter, code, link/image, wiki и math ranges защищены.
- **Три режима:** Source получает plugin spans и не выдаёт core checkbox lint; Visual хранит inline payload в `.mdBuiltInPluginToken`, list payload в `.builtInPluginTaskItem`, сериализует исходный `[marker]` и циклически меняет marker/list/table с undo; Preview рендерит доступную кнопку, SF Symbol как локальный PNG data URI и отправляет source offset через отдельный WebKit handler. Strike-state зачёркивает list item.
- **Таблицы:** native cells рендерят inline widget; virtualized large-table path использует тот же renderer/cache, а status-only cell циклически обновляется через существующий `updateTableIslandCell`, что покрывает `PMID_DOWNLOAD_LIST.md` без перевода большой таблицы в NSTextTable.
- **UI/docs:** Settings ▸ Plugins — read-only inventory встроенных плагинов; подробный developer/user контракт и пример frontmatter находятся в `docs/plugins.md`.
- **Тесты:** `BuiltInPluginsTests` — 23 кейса: schema/order/icons/strike (включая все markers из `PMID_DOWNLOAD_LIST.md`), canonical indentationless YAML sequence, invalid config, protected syntax, list/prose/table scan, escaped marker в island-cell, cached-snapshot cycle через states, отсутствовавшие при загрузке, frontmatter-scoped snapshot refresh, UTF-16 mask, cycle+wrap и очистка старого attachment/strike, Source/lint, Visual round-trip, Preview HTML/bridge, точный sentinel offset/fallback, hit-rect и отключение обычных checkbox при activation.

### Plugin review hardening

- **Visual safety:** неописанные core `[ ]`/`[x]` тоже входят в text-token restore. U+E001 никогда не попадает в `NSTextStorage`; неинтерактивный semantic run сохраняет исходный marker дословно при serialize, но не участвует в hit-testing.
- **Click contract:** inline token цикличится только при попадании в bounding rect его glyph range. Ближайший glyph от клика справа или ниже строки больше не считается hit.
- **Hot path:** registry сначала делает дешёвый frontmatter gate и не вызывает cmark для неактивного документа. Snapshot один раз сортирует tokens, а source lookup строит из полной цепочки configured states, поэтому cached snapshot продолжает цикл даже через marker, которого не было при загрузке. Visual не парсит документ в `applyPresentation`; `syncToDocument` сравнивает дешёвый raw frontmatter source и только при его изменении перестраивает snapshot и один раз re-render-ит semantic model.
- **Tables/Preview:** large-table cell строит один `Document`; тот же AST задаёт code/link/image context, wiki/math фильтруются локально, а raw slice конкретного Text берётся прямо по UTF-8 source columns — `\[?\]` остаётся literal без отдельного `collectCoreSpans`/`LineIndex`. Preview сопоставляет sentinel на точном source offset через document-order cursor за O(n), при отсутствии AST range использует следующий semantic token, а при mismatch восстанавливает original source slice.
- **Commands/capabilities:** Format ▸ Checklist считает core и plugin tasks одной checklist-family и для действия, и для active menu indicator; в активном документе новая checklist начинается с первого state из frontmatter. Lint спрашивает у registry capability `ownsCoreCheckboxSyntax`, а не знает `MultiCheckboxPlugin` напрямую.
- **YAML:** parser принимает как indented sequence под `states:`, так и канонический indentationless sequence с `- marker:` на том же indent.
- **Preview editor continuity:** persistent shell переносит plugin ID, state index, active control и selection через замену `#preview-content`; Swift заранее сбрасывает `hasEditablePreviewFocus`, чтобы удалённый WebKit node не блокировал Return-to-edit. Невалидный объявленный блок, включая duplicate marker, показывает diagnostic card, а пустой frontmatter не создаёт пустую карточку «Свойства».
- **Visual invalid configuration:** read-only Visual показывает registry diagnostic в статус-баре как `Multi-checkbox · Needs attention`; tooltip объясняет ошибку, клик открывает Source на frontmatter. Preview marker input больше не эмитит неиспользуемый `data-initial`.

### Plugin gotchas

- Plugin snapshot строится до удаления frontmatter, но маска Preview получает `sourceOffset=baseOffset`; иначе ranges после properties card смещаются.
- U+E001 может быть разбит cmark по Text nodes, поэтому каждый Preview sentinel run сверяется с token на вычисленном UTF-16 source offset; order-only cursor здесь опасен, потому что один пропущенный run сдвигает все последующие widgets.
- При цикле SF Symbol → emoji нужно удалить старый `.attachment` из унаследованных attributes; иначе новый текст продолжает рисовать прежнюю картинку.
- `EditMD/project.yml` до этого отставал от уже сгенерированного `0.40.2 (402)` в dirty worktree; источник истины синхронизирован с существовавшей версией перед xcodegen, без нового version bump.

## Сворачиваемый frontmatter — app **0.41.0**

- Visual и Preview показывают единый заголовок «Свойства» с disclosure-chevron (вниз при раскрытом блоке, вправо при свернутом). Клик по всей строке сворачивает весь блок свойств и активную карточку настройки плагина до одной строки; повторный клик раскрывает его.
- Visual меняет только display-представление `.raw`-острова. Verbatim YAML с фенсами остаётся payload блока и одинаково сериализуется в раскрытом и свернутом состоянии.
- Активный multi-checkbox в раскрытом Visual не сжимается до бесполезного `editmd:`: read-only legend показывает каждое состояние в порядке цикла как «иконка — `[marker]` — название» и визуально отмечает strikethrough-state. Поля редактирования остаются только в Preview/Source.
- Preview хранит disclosure state в persistent WebKit shell, а не внутри заменяемого `#preview-content`, поэтому live `innerHTML` update не раскрывает карточку обратно. После каждой замены новый frontmatter получает текущее shell-state при hydration.
- Редактируемый конструктор произвольных frontmatter-полей в Visual не добавлен: текущий Visual island остаётся read-only. Для безопасного конструктора нужен отдельный AppKit overlay с typed YAML mutations и undo, аналогичный whitelist bridge Preview, а не редактирование display-текста острова.
