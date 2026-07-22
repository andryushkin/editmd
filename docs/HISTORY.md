# EditMD — история версий

История релизов и post-release спринтов: что сделано, почему и какие gotchas пережили ревью. Вынесена из `CLAUDE.md` (2026-07-10), чтобы рабочий гайд оставался коротким. Перед работой над конкретной подсистемой (таблицы, wiki-links, frontmatter, split preview, изображения…) читай её раздел здесь.

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
- **`columnWidth == 0`** = full width. `ModeSettings.textContainerInset(forWidth:)` считает доп. горизонтальный inset так, чтобы центрировать колонку заданной ширины: `extra = max(0, (viewWidth - insetH*2 - columnWidth) / 2)`. Source/Visual зовут это от `scrollView.contentView.bounds.width` — **не в `makeNSView`** (там ширина ещё 0); центрирование “на живую” при ресайзе окна работает благодаря тому, что `ContentView`‘s `GeometryReader` перевызывает body при смене `geo.size`, а SwiftUI зовёт `updateNSView` на каждый такой ре-рендер родителя (не только когда сам representable’s props изменились). **Source с 2026-07-21 переприменяет геометрию ещё и в `layout()`** — путь через `updateNSView` приходил ПОСЛЕ первой отрисовки, поэтому файл с заданной колонкой мигал один раз: узкое поле, затем широкое. `layout()` предшествует отрисовке, так что первый кадр уже финальный; вызов переиспользует кэш `gutterReserveWidth` (пересчёт считает строки документа), защищён флагом от рекурсии `insets → layout → insets` и инвалидирует отрисовку только при реальном изменении геометрии. В Visual тот же паттерн `makeNSView`-при-нулевой-ширине остаётся — там мигание проявится только при `columnWidth > 0`
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
- **Сайдбар.** `WorkspaceModel` (несколько workspace-папок, скрытые по папкам, пины loose-файлов, session-loose; персист UserDefaults по пути) + `WorkspaceSidebar` (сегмент Files/Outline, глаз показывает скрытые с restore, пины, ПКМ). Активный корень отмечается только синей иконкой папки: фон и текст заголовка остаются нейтральными, чтобы не конкурировать с выбранным файлом. File▸Open Folder ⇧⌘O.
- **Создание корневой папки (2026-07-15).** Плюс в Files различает `New Folder…` и `Open Folder…`: первый открывает save-style panel, где выбирают родительский каталог и имя ещё не существующей папки, затем создаёт её, добавляет в сайдбар и открывает. Во внешнем UI это «папка»; `Workspace` остаётся внутренним термином для корня Git/Review/integration scope.
- **Имя папки и display name (2026-07-15, hardened 2026-07-16).** По умолчанию корень показывается как настоящая папка. Пользователь может отдельно задать отображаемое имя EditMD; если оно отличается, карточка папки показывает обе сущности. Из сайдбара и карточки доступны отдельные команды для display name и физического rename. Rename на диске переносит path-keyed state/snapshot/history для корня и всех вложенных adopted roots, включая их hidden-state; закрытые модели `DocumentRegistry` и их undo re-keyed под новый корень, а при неоднозначном исходе сбрасываются. Открытый документ внутри корня блокирует операцию: autosave и watchers привязаны к прежнему URL. Транзакция сначала получает эксклюзивный FIFO permit `ReviewModel`, затем без следующей suspension ставит `AppState`-gates на старый и ожидаемый новый корень: Finder/control-открытия и sidecar-действия ждут завершения и переигрываются по фактически выжившему URL. Неоднозначный rollback сбрасывает действия для небезопасных корней вместо воскрешения пути; отсутствующий до старта source никогда не принимает за survivor чужую папку по destination. Case-only rename на нечувствительном к регистру томе проходит через уникальный временный sibling; если второй move и rollback оба падают, наружу возвращается фактически выживший old/new/temp URL.
- **Режим нового файла (2026-07-15).** Файл, созданный из карточки папки, и untitled через File ▸ New открываются в Visual. Обычная навигация по существующим файлам сохраняет выбранный режим, Finder/Dock по-прежнему открывает Preview.
- **Перемещение файлов (2026-07-15, hardened 2026-07-16).** Файл можно перетащить на корень workspace, подпапку или открытую карточку папки либо вызвать «Переместить…» и выбрать каталог. ⌘-клик переключает отдельные строки, Shift-клик выделяет видимый диапазон от последнего selection anchor; drag или команда на выбранной строке переносит весь набор. Drag transport использует явный `NSItemProvider` с одним маркированным JSON payload группы под системным `public.json`: собственный UTI не был зарегистрирован в app bundle и поэтому не согласовывался реальным AppKit drag session, хотя provider unit-тест мог загрузить его напрямую. Source и destination используют одну константу типа, а случайный process token не даёт принять внешний JSON за внутренний перенос. Batch сначала проверяет все источники, одинаковые basename, существующие destinations и destination-sidecar (даже если у source нет review), затем выполняет disk moves. `.review.json` следует за каждым файлом. Ошибка посередине откатывает уже перенесённые пары; если rollback сам падает, фактическое наличие file/sidecar по обоим путям перепроверяется, path-keyed state и parked presentations привязываются к реально выжившим destinations, а split/ambiguous state остаётся явной ошибкой. До disk I/O транзакция получает общий Review FIFO permit и `AppState`-gates, резервирует сначала все destinations, затем без suspension все sources, и лишь после этого начинает off-main persist: поздние save, `marks.add/list`, agent edit и внешние open не воскрешают старый путь и не занимают будущий destination. Открытые и cached Markdown переносятся через отдельный uncapped prepared-store; clean buffer не переписывается, dirty/unmarked snapshot сохраняется off-main. Обязательная сверка с диском держит dismissed-конфликт unresolved до явного Disk/Mine/save, а для `.textbundle` сравнивает рекурсивный content-fingerprint assets, отделяя локально добавленную картинку от внешней замены её байтов. После batch те же модели и undo восстанавливаются по итоговым URL; route replay выполняется атомарно в исходном FIFO-порядке, а неоднозначные пути сбрасываются явно. Hidden/loose/pinned, last-active, sidebar snapshot, history, tags и wiki-link index мигрируют для каждого файла. Общий `LongRunningOperationCenter` сразу блокирует ввод, но показывает material-overlay с `ProgressView` только после 250 мс, поэтому быстрые операции не мигают; слой подключён ко всем main/lite/settings roots и поддерживает перекрывающиеся задачи. Относительные markdown-ссылки внутри переносимых документов автоматически не переписываются.
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
  - **Caret-tie-break (0.47.x)**: вставка строки, дословно совпадающей с соседней (второй одинаковый пункт списка / строка таблицы), — фундаментально неоднозначна для чистого line-diff: `CollectionDifference` вправе приписать новую строку любой из равных строк прогона и подсвечивал **несдвинутую, нетронутую** строку зелёной точкой/номером. `dirtyLineNumbers` теперь принимает `caretLine` и `snapMarksToCaret` переносит метку на строку каретки, если та контент-идентична помеченной и между ними только равные строки (счётчик меток не меняется → мульти-регион правки не задеваются). Source передаёт `caretUTF16Offset` (O(1)); offset→строка резолвится там же, где идёт diff — inline для мелких буферов, off-main для крупных (резолв на main per-keystroke вернул бы хич на больших файлах). Visual пока шлёт `nil` (маппинг визуальной каретки в source-строку не сделан; round-trip Visual каноничен, дубли-строки там редки).
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

## PDF-спринт — просмотр файлов и локальные markdown-ссылки

- PDF открываются read-only через PDFKit в главном и lite-окнах, мимо `DocumentRegistry`. Файлы участвуют в sidebar/tree stats, File ▸ Open и wiki-link resolution; bare `[[Name]]` предпочитает markdown, явное расширение фиксирует тип.
- Локальные markdown-ссылки резолвятся как в Obsidian: `/path` — от корня adopted workspace (fallback — ближайший `.obsidian`), относительный путь — от папки документа; fragment и percent encoding нормализуются. Markdown/PDF открываются внутри EditMD, остальные типы — системой.
- Preview ловит schemeless href через JS bridge: `loadHTMLString(baseURL: nil)` не даёт браузеру полезной базы, поэтому одного `WKNavigationDelegate` недостаточно. Visual открывает локальную `.mdLink` по ⌘-клику без требования URL scheme.
- `PDFViewerHost` и последующий `ImageViewerHost` используют общий `MediaViewerHost` для sidebar/window chrome.

## Формулы-спринт (после PDF-спринта) — $…$ / $$…$$ с KaTeX в Preview — app **0.39.0**

Отображение LaTeX-формул: `$inline$` и `$$display$$` через все три режима. Preview — настоящий рендер (KaTeX, офлайн), Source/Visual — подсветка сырого TeX.

- **`MathScan.swift`** — чистый сканер `scanMathSpans(in:)` (UTF-16, NSString): inline `$…$` (opener не перед пробелом, closer не после пробела и не перед цифрой — валютный гард `$20 и $30`), display `$$…$$` (однострочный — где угодно; многострочный — только если `$$` открывает строку и внутри нет `>`-строк, иначе маска сломала бы blockquote). Код пропускается: fenced (```/~~~), indented (4+ пробела вне параграфа), однострочные `` `код` ``. `\$` не открывает/не закрывает.
- **Маскированный парс в Preview** (`maskMathSpansForParsing`): содержимое спанов заменяется U+E000 (PUA) **юнит-в-юнит** — UTF-16-длина и позиции переводов строк сохраняются, поэтому все оффсеты из парса маскированного текста валидны в оригинале (`data-md-lo/hi`, gutter `data-ln`). cmark не видит TeX → `\frac`/`_`/`*`/`\\` не калечатся. Ведущие пробелы строк внутри спана не маскируются (вложенность списков живёт). `LineIndex` строится от **маскированного** текста (колонки cmark = UTF-8 байты того, что он парсил; сентинел 3 байта).
- **`HTMLBodyVisitor`**: `visitText` режет ран на плain-сегменты и сентинел-раны; учёт по счётчику юнитов (`HTMLMathSpan.units`) — первый ран спана эмитит `<span class="math math-inline|math-display" data-md-lo/hi data-md-code="1">TeX</span>`, хвосты (многострочный `$$` разрезан softbreak'ами) поглощаются молча. `data-md-code="1"` = selection-остров (как рендеренный код), wash ревью-меток по `data-md-lo` работает.
- **KaTeX офлайн** (`Resources/katex/` + `KaTeXResources.swift`): katex.min.js 0.16.22 (277KB) + katex.css с woff2-шрифтами как data-URI (367KB, собран из npm-дистрибутива). Страница грузится `loadHTMLString(baseURL: nil)` — внешние файлы недоступны, поэтому всё инлайном, и **только когда формулы есть** (`markdownHTMLRender` → `hasMath`). Рендер-скрипт: `katex.render(textContent, el, {throwOnError:false})` + повторный `alignLineNumberGutter()` после рендера и `document.fonts.ready`. Display-блоки выровнены ПО ЛЕВОМУ краю с отступом 2em (не по центру — просьба пользователя; `.katex-display`-центрирование KaTeX переопределено). Без ассетов — graceful: виден сырой TeX.
- **Source**: `collectSpans` тоже парсит маскированный текст (никаких setext-H1/emphasis внутри TeX) + пост-скан → `.mathBody(display:)` (цвет `els.inlineCode.color ?? theme.inlineCodeColor`) + `.mathMarker` (secondary) — в обоих аппликаторах (Coordinator + `makeSourceHighlightedString`).
- **Visual**: парсит ТОЖЕ маскированный текст (как Preview) — `=`-строка внутри `$$` больше не делает блок setext-H1, `\\`/`\,` не разэскейпливаются. **Формулы РЕНДЕРЯТСЯ** (раунд 3, по просьбе пользователя): SwiftMath 1.7.3 (нативный порт iosMath, SPM) типографит TeX в NSImage → `NSTextAttachment` с базовой линией из `LayoutInfo.descent` (`MathAttachment.swift`); вербатим-источник (`$…$`/`$$…$$`, с реальными `\n`) лежит в атрибуте `.mdMathTex`, сериализатор эмитит его как есть. Однострочные матчи в `appendTextWithWikiLinks` слиты с wiki-матчами; многострочный `$$` перехватывается на уровне блоков (`multilineMathIndex`) — один аттачмент на весь спан, blank-line-осколки пропускаются. TeX, который SwiftMath не разобрал, остаётся тонированным сырым текстом (`.mdMath`, U+2028 для переносов) — тоже вербатим при сериализации. **Редактирование — двойной клик по формуле** → transient NSPopover (`MathEditorPopover.swift`): моно-поле TeX + живое превью, ⌘⏎/OK применяет (undoable replace через shouldChangeText), пустой TeX удаляет формулу, Esc/клик мимо отменяет; guard на staleness (документ изменился, пока попап открыт → beep). Кнопка ∫ в strip вставляет формулу и сразу открывает редактор. В сериализаторе голый U+FFFC без payload (чужой аттачмент из буфера) глотается — не попадает в файл.
- **Тесты:** `MathScanTests` (сканер/гарды/маска/аттачменты, 25 кейсов) + 8 math-кейсов в `MarkdownHTMLTests` + 4 round-trip фикстуры (всего 697).

### Формулы-спринт — gotchas
- **Цвет формулы-картинки был запечён при рендере** (`resolvedLabelColor` через effectiveAppearance) — переключение Light/Dark не перекрашивало аттачменты. Исправлено в 0.39.2 ниже через tint на отрисовке.
- **Copy/paste формул внутри Visual может потерять `.mdMathTex`** (RTFD не переносит кастомные ключи) — сериализатор глотает голый U+FFFC, формула тихо исчезает из markdown; вставлять формулы заново через ∫ или Source.
- **Покрытие TeX у SwiftMath ≠ KaTeX** — что не разобралось, показывается сырым тонированным текстом (и корректно сериализуется); Preview может отрендерить то, что Visual не смог.

- **xcodegen плющит Resources в корень бандла** — `Resources/katex/katex.css` лежит как `Contents/Resources/katex.css`; `KaTeXResources.load` пробует subdirectory и падает на корень.
- **Многострочный `$$` требует: opener открывает строку, closer закрывает строку** (только пробелы вокруг) — контракт «спан = целые строки», на котором держится блочный перехват в Visual.
- **`\$` в Visual теряет эскейп при сериализации**: cmark разэскейпит `\$`→`$` в plain-тексте, а `escapeInline` `$` не эскейпит (иначе валютные `$20` в любом документе получали бы diff-шум) — literal `$x$` после Visual-редактирования может стать формулой. Корнер, признан.
- **Многострочный `$$` в blockquote не поддержан** (сканер отказывает — маска съела бы `>`); однострочные формы работают везде, включая таблицы и заголовки.
- **Сентинел-учёт полагается на документ-порядок** Text-узлов; документ, сам содержащий U+E000, may съесть спан (guard: молча ничего не эмитим, не падаем).

## Подсветка кода — app **0.39.1**

- `HighlighterSwift` запускает highlight.js через JavaScriptCore. `CodeSyntaxHighlighter` — общий источник токенов для Source/Visual и HTML-спанов Preview/PDF; aliases языков нормализуются, блоки без языка не автодетектятся.
- Каждый токен несёт light+dark palette. Source/Visual получают dynamic `NSColor`, HTML — CSS variables; appearance выбирается на отрисовке.
- Editor path работает cache-first и прогревает промахи off-main (`stale-while-revalidate`). Blocking разрешён только для разового HTML/export. Frontmatter YAML использует тот же pipeline.
- Performance guard: code blocks длиннее 8192 UTF-16 units остаются plain, потому что regex worst cases highlight.js могут надолго занять JavaScriptCore и его parallel GC. Фоновые промахи прогреваются ограниченными пакетами; Source/Visual получают одно repaint-уведомление после опустошения пакета, а не полный presentation pass после каждого блока.

## Формулы и appearance — app **0.39.2**

- Формулы Visual больше не запекают `NSApp.effectiveAppearance`: один силуэт тонируется при draw через `NSImage(size:flipped:drawingHandler:)`, `cacheMode = .never`.
- Display formulas в Preview получили внешний вертикальный ритм на `.math-display`; внутренний margin KaTeX обнулён, иначе BFC из-за overflow складывал оба отступа.

## Гаттер и action strip — app **0.39.3**

- Переключатель режимов и line-number toggle перенесены в `EditorActionStrip`; `StripItem` — единый источник для pill и overflow menu.
- Source/Visual рисуют номера в зарезервированном левом text inset через `LineNumberGutter`, а не `NSRulerView`, который прибивает цифры к краю scroll view.
- Strip и gutter используют общую `EditorFieldGeometry`; Preview повторяет те же метрики в HTML/CSS. Дублирование формул геометрии уже приводило к рассинхрону.

## Split scroll и live Preview — apps **0.39.4–0.40.2**

- Двусторонний scroll sync использует отдельный `previewScrollOffset`, чтобы транспорт split-прокрутки не затирал каретку. Позиция непрерывная и привязывается к markdown offsets/data anchors внутри блоков.
- Live Preview обновляет существующий WKWebView через JS bridge и сохраняет scroll/focus; тяжёлые HTML/KaTeX/image операции кэшируются и не должны замораживать печать.
- Рендер и scroll callbacks имеют echo/throttle guards: editor→preview и preview→editor не образуют feedback loop.
- В 0.40.2 Preview-strip сокращён до действий, которые честно работают в read-only DOM; ID инструментов и overflow routing сведены к одному источнику.

## Image viewer и вставка изображений (после **0.40.2**)

Серия `e2bcfa1..668a1f1`: просмотр локальных изображений, кнопка добавления и paste из буфера с последующим ревью регрессий.

- **Viewer:** форматы `png/jpg/jpeg/gif/svg/webp/heic/tiff/tif/bmp` маршрутизируются в native image canvas; MIME/extension/picker routing питаются от `supportedImageMIMETypes`. PDF и image windows разделяют `MediaViewerHost`.
- **Insertion:** picker и clipboard кладут байты в `assets/` и вставляют относительный `![alt](destination)`. `markdownImageSyntax` общий для insertion и round-trip; destination/alt не экранируются второй независимой реализацией.
- **Paste funnel:** Source пробует table → image → plain text; Visual — markdown/table → image → plain text. Порядок lazy: Word/Excel/Numbers кладут рядом HTML и TIFF/PDF preview, поэтому image-first убивал табличную вставку.
- **Контекст:** Source внутри fenced block не запускает special doors; Visual использует общий `visualContextAllowsStructuredPaste` для markdown, image paste и кнопки и запрещает структуру в `codeBlock`, `tableCell`, `.raw`.
- **Fallback:** storage error возвращает `false`, чтобы обычный paste получил текстовую часть payload. `true` означает, что вставка действительно состоялась или payload намеренно потреблён.
- **Assets:** повторные байты переиспользуют существующий файл. Дедуп сначала фильтрует по size и только затем сравнивает содержимое. В textbundle диск — источник существующих assets, найденный файл добавляется в `assetsFileWrapper`; генерация имени дополнительно проверяет `fileExists`, включая hidden/symlink collision.
- **Reload:** `ImageCanvasView` сравнивает URL + mtime + size и делает stat/read в detached task. При смене URL старая канва очищается и виден loading; при обновлении того же URL старая картинка остаётся до успешной замены. Проверка запускается оппортунистически из `updateNSView`, отдельного watcher нет.
- **Тесты:** routing/guards/fallback, markdown serialization, collision/content dedup, textbundle disk-without-wrapper и file-version покрыты в `VisualEditingTests`; полный suite после финального фикса — 766 тестов.

### Image sprint — gotchas

- Не ставить broad image-flavor перед семантическими paste doors: TIFF часто является лишь рендером другого clipboard payload.
- Не делать synchronous file read в `updateNSView` или SwiftUI `body`. Paste хранит asset синхронно только потому, что AppKit требует немедленно решить, разрешать ли plain-text fallback; поэтому scan должен оставаться metadata-first.
- `showLoading` имеет разную семантику для URL change и same-URL reload: в первом случае чужие пиксели опаснее мигания, во втором полезно сохранить текущую картинку.
- Не сканировать `FileWrapper.regularFileContents` без size metadata: для открытого textbundle те же assets уже находятся на диске и проходят общий disk dedup.

## Встроенные плагины и multi-checkbox (после **0.40.2**)

- **Граница архитектуры:** плагины только встроенные и скомпилированные на Swift. `BuiltInMarkdownPlugin` + `BuiltInPluginRegistry` дают метаданные, document-scoped activation и semantic tokens; загрузки JavaScript, внешних bundle, marketplace и стороннего executable code нет. Это сознательно сохраняет hardened-runtime модель и не вводит отдельный permissions/sandbox/XPC слой.
- **Frontmatter activation:** `editmd.plugins.multi-checkbox.states` — упорядоченный список состояний (`marker`, optional `label`, `icon`, `strikethrough`). `sf:<name>` использует SF Symbols, `emoji:<text>` — emoji. Минимум один уникальный marker; порядок определяет цикл с wrap последнего в первый. Одно-state шаблон показывает иконку, но не получает ложный click target до появления второго состояния.
- **Checkbox ownership:** валидная конфигурация забирает checkbox-семантику всего файла. Описанные `[marker]` становятся multi-checkbox; неописанные core `[ ]`/`[x]`/`[X]` маскируются как literal text, а не остаются вторым двухсостоянийным механизмом. Без frontmatter стандартный GFM task list не меняется.
- **Общий range contract:** `BuiltInPluginSnapshot` хранит UTF-16 ranges оригинального markdown. Для cmark parse копия length-preserving: list token нормализуется в `[ ]`, inline token маскируется U+E001; delayed Preview click перед заменой повторно сверяет offset/source. Frontmatter, code, link/image, wiki и math ranges защищены.
- **Три режима:** Source получает plugin spans и не выдаёт core checkbox lint; Visual хранит inline payload в `.mdBuiltInPluginToken`, list payload в `.builtInPluginTaskItem`, сериализует исходный `[marker]` и циклически меняет marker/list/table с undo; Preview рендерит доступную кнопку, SF Symbol как локальный PNG data URI и отправляет source offset через отдельный WebKit handler. Strike-state зачёркивает list item.
- **Таблицы:** native cells рендерят inline widget; virtualized large-table path использует тот же renderer/cache, а status-only cell циклически обновляется через существующий `updateTableIslandCell`, что покрывает `PMID_DOWNLOAD_LIST.md` без перевода большой таблицы в NSTextTable.
- **UI/docs:** Settings ▸ Plugins — read-only inventory встроенных плагинов; подробный developer/user контракт и пример frontmatter находятся в `docs/plugins.md`.
- **Document install door:** фиксированное puzzle-menu общей action strip доступно в Source/Visual/Preview/Split и строится из registry descriptors. Multi-checkbox вставляет undoable одно-state шаблон: создаёт frontmatter с нуля либо вкладывается в существующие `editmd`/`plugins`; declaration gate не допускает второй блок даже при невалидной существующей конфигурации.
- **Preview configuration:** активный plugin frontmatter заменяет сырой вложенный `editmd`-ряд на интерактивную карточку состояний. Add state, marker, label, Emoji/SF Symbol/Text и strikethrough идут через typed WebKit bridge, registry whitelist и общий undo path; системная Character Viewer вставляет emoji в сфокусированное поле. Inline lint не пропускает multi-unit, `[`/`]` и duplicate markers, а неизвестный SF Symbol виден в строке. Marker rename мигрирует существующие semantic tokens, сохраняя code/link/wiki/math; YAML-комментарий на изменяемой строке сохраняется.
- **Preview editor continuity:** перед заменой `#preview-content` persistent shell запоминает plugin ID, state index, control и selection, после hydration восстанавливает их без scroll jump. Swift перед каждой fragment replacement сбрасывает `hasEditablePreviewFocus`; новый `focusin` выставляет его снова, поэтому удалённый WebKit node не блокирует Return-to-edit навсегда. Невалидный объявленный блок (включая duplicate marker) получает видимую diagnostic card вместо тихого отключения, а пустой frontmatter без свойств не создаёт пустую карточку «Свойства».
- **Visual invalid configuration:** read-only Visual не пытается строить редактор невалидного YAML. Registry diagnostic появляется в статус-баре как `Multi-checkbox · Needs attention`; tooltip объясняет ошибку, клик открывает Source на frontmatter. Preview-only marker input больше не эмитит неиспользуемый `data-initial`.
- **Тесты:** `BuiltInPluginsTests` и Swift Testing suite конфигуратора покрывают schema/order/icons/strike (включая markers из `PMID_DOWNLOAD_LIST.md`), one-state activation, установку во все формы frontmatter, add-state, declaration gate, canonical indentationless YAML sequence, invalid config, protected syntax, Source/Visual/Preview round-trip/bridge, cycle+wrap и отключение обычных checkbox при activation.

### Plugin review hardening

- **Visual safety:** неописанные core `[ ]`/`[x]` тоже входят в text-token restore. U+E001 никогда не попадает в `NSTextStorage`; неинтерактивный semantic run сохраняет исходный marker дословно при serialize, но не участвует в hit-testing.
- **Click contract:** inline token цикличится только при попадании в bounding rect его glyph range. Ближайший glyph от клика справа или ниже строки больше не считается hit.
- **Hot path:** registry сначала делает дешёвый frontmatter gate и не вызывает cmark для неактивного документа. Snapshot один раз сортирует tokens, а source lookup строит из полной цепочки configured states, поэтому cached snapshot продолжает цикл даже через marker, которого не было при загрузке. Visual не парсит документ в `applyPresentation`; `syncToDocument` сравнивает дешёвый raw frontmatter source и только при его изменении перестраивает snapshot и один раз re-render-ит semantic model.
- **Tables/Preview:** large-table cell строит один `Document`; тот же AST задаёт code/link/image context, wiki/math фильтруются локально, а raw slice конкретного Text берётся прямо по UTF-8 source columns — `\[?\]` остаётся literal без отдельного `collectCoreSpans`/`LineIndex`. Preview сопоставляет sentinel на точном source offset через document-order cursor за O(n), при отсутствии AST range использует следующий semantic token, а при mismatch восстанавливает original source slice.
- **Commands/capabilities:** Format ▸ Checklist считает core и plugin tasks одной checklist-family и для действия, и для active menu indicator; в активном документе новая checklist начинается с первого state из frontmatter. Lint спрашивает у registry capability `ownsCoreCheckboxSyntax`, а не знает `MultiCheckboxPlugin` напрямую.
- **YAML:** parser принимает как indented sequence под `states:`, так и канонический indentationless sequence с `- marker:` на том же indent.

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

## AI ready (план 09)

- Единое лицо: тулбар ✨ (`AgentActivityModel` + popover, промпты, badge, toast, Stop).
- `editmdctl agent-status` + `Resources/agent-status/*` (no-op wrapper, Claude/Codex/pi/shell).
- Skill-пакет `Resources/agent-skill/` → `~/.claude/skills/editmd` и `~/.codex/skills/editmd`.
- Settings ▸ Integrations: статусы, installers, пресет ✈️, `EDITMD_*` env на spawn.
- `AIProposalChrome` — общий Accept/Decline; clean external reload → toast.
- Target `editmd-mcp` (stdio → control socket); openDiff по-прежнему только /ide.
- Follow-up: auto-merge MCP registration в `~/.codex/config.toml` / `.mcp.json`.

## Workspace search (план 07)

- Левый сайдбар: вкладка Search (`magnifyingglass`) — workspace full-text. Нижний Filter скрыт (своё поле запроса).
- `Editor/SearchQuery.swift` — парсер `токены`, `"фраза"`, `path:` / `type:` / `tag:` / `is:modified` / `after:` / `before:`; неизвестный `key:` → token.
- `Editor/SearchMatch.swift` — чистые meta/content matchers, лимит 200 файлов / 4 МБ skip, LRU content cache ~64 МБ, sort по matchCount или mtime.
- `Views/WorkspaceSearchModel.swift` — debounce 300 мс, off-main scan, cancellation. Диск only (буферы не мержатся).
- `is:modified` — `WorkspaceSearchGitBridge` переиспользует snapshot Git-вкладки; Process только при stale. `tag:` — `WorkspaceModel.tagIndex`.
- Переход: `AppState.requestControlJump` + `onOpen` (как vault-lint / wiki heading).

### Case-fold: профиль → scalar-fold (2026-07-20)

- v1 матчер использовал Foundation `range(of:options:.caseInsensitive)` — «Cyrillic-safe без locale-ловушек». Осторожность todo была «не оптимизировать вслепую, сначала профиль»; предыдущий вывод (2026-07-19) верно отверг «убрать двойной проход» (не-совпавшие файлы отсекаются `guard matched` до line-scan, так что двойной фолд платят только редкие совпавшие).
- **Профиль на WoL-волте (standalone-бенч, 7010 md / 50 МБ, whole-body скан по токену):** Foundation caseInsensitive = **3–6.8 с/токен**. Case-sensitive без фолдинга ≈ 0.65–1.0 с (фолдинг ×4–5), остальное — grapheme-cluster итерация. Истинный bottleneck — **whole-body casefold по всем meta-passed файлам**, а не double-pass.
- **Решение — scalar-fold** (`searchFoldScalar` в `SearchMatch.swift`): ручной simple-lowercase по Unicode-скалярам, таблица **узкая и осознанная** — ASCII A–Z, Latin-1 À–Þ (кроме ×), кириллица А–Я + Ѐ–Џ (вкл. Ё). Прочие скаляры проходят **case-sensitive**. `searchContentMatches` фолдит тело/имя/needles по одному разу (`searchFolded` → `[UInt32]`) и гоняет `searchFoldedContains`/`searchFoldedOccurrenceCount` (non-overlapping). Байтовый ASCII-fold из todo **отвергнут** — ломает кириллицу (регистр меняет lead-байт UTF-8 у р/Р).
- **Результат:** 100% count-parity с Foundation на волте (вкл. `Витамин`==`витамин`, `КЛЕТКА`==`клетка`); ~10–17 мс/токен после 255 мс однократного fold → **~270 мс/запрос vs 4–13 с (15–45×)**. `SearchMatch.swift` в offline-таргете `editmdctl` → правка Foundation-only, ускоряет и `editmdctl search`.
- **Инвариант расширения:** нужен ещё скрипт (греческий, турецкий İ и т.п.) — **дописывать таблицу `searchFoldScalar`**, не откатываться в grapheme-path Foundation.
- **Хвост подсветки:** `WorkspaceSearchSidebar.highlightedLine` осознанно оставлен на Foundation `.caseInsensitive` — ему нужен `String.Index`-диапазон (скаляр-примитивы дают bool/count). Одна короткая уже-совпавшая строка; на скриптах таблицы совпадает со scalar-hit, вне таблицы — косметика.
- **Возможный будущий прирост (не сделано):** LRU content cache хранит raw text; повторные запросы снова фолдят тело. Кэшировать folded `[UInt32]` рядом/вместо raw — убрало бы 255 мс на повторах. 270 мс уже interactive, поэтому отложено.

## Vault-lint (план 06)

- `Editor/VaultLint.swift` — чистая функция `vaultLintFindings` по `LinkIndexSnapshot`: dead/ambiguous/self wiki, dead relative (в т.ч. за пределы roots), dead image, orphan (без README/index home), dead heading (если в индексе есть titles).
- `LinkIndex` хранит `headings` из outline при scan; `snapshot()` + `homeDocument` для orphan-исключений.
- `VaultLintModel` пересчитывает off-main после обновления индекса; View → «Проверить ссылки workspace» и Info → «Проблем в workspace: N».
- Per-file: Source lint merge + `vaultLintDidUpdate` notification. Vault-находки отстают до save/index (осознанно). Без автоправок.
- On-demand vault-lint отменяет текущий full run при закрытии report-панели. Per-file refresh делит один in-flight `WikiRankCatalog`, ключованный поколением набора файлов; snapshot и сортированный список строятся один раз на ревизию индекса. Per-file task очищается только по собственному generation-token, а первый пустой результат не шлёт лишний merge. Byte-wise ranking работает по заранее canonical-normalized ключам для composed/decomposed Unicode filenames.

### Performance hardening link/git paths (2026-07-18)

- Link scan больше не вычисляет line/context полным проходом от начала для каждой ссылки; `LineIndex` даёт бинарный поиск. Full `LinkIndex` хранит parse-cache по `(mtime, size)`, а его task теперь имеет владельца: новый epoch отменяет устаревший walk/resolution, частичный cache не публикуется, cancellation проверяется и внутри link-dense файла.
- Vault-lint строит lowercased `WikiRankCatalog` один раз за run и memoize-ит suggestion по target. Wiki completion хранит такой же prebuilt catalog, созданный off-main вместе с файловым каталогом; per-keystroke ranking держит только top-N вместо сортировки всех совпадений.
- Git status-bar refreshes сериализованы actor’ом. `CollectionDifference` синхронный и не умеет остановиться в середине, поэтому отмена старого refresh не должна запускать параллельно новый Myers diff или вторую цепочку git-процессов.
- Visual serializer возвращает paired display/markdown paragraph ranges. Dirty-line caret lookup делает бинарный поиск по готовой карте вместо прохода всех display paragraphs от начала на каждом keystroke.

## История файла (план 05)

- Вкладка «История» в правом inspector: **Не сохранено** (буфер vs `knownDiskContent`), **Локальные ревизии**, **Git** (`git log --follow --max-count=50`).
- `Document/FileRevisionStore.swift` — content-addressed store в Application Support (`revisions/<sha256(path)>/{manifest.json,objects/}`); дедуп по content SHA, debounce 5 мин, prune 100, skip >4 МБ. Flush DocumentRegistry пишет в фоне; close clean-документа — force snapshot. Rename/move путь не мигрирует историю (v1).
- `Document/FileHistoryGit.swift` — NUL-парсер log, `git show rev:path`, кэш по HEAD; инвалидация от `gitRepositoryDidChange`.
- Diff — `DiffTextRepresentable` / unified sheet; restore через `applyDocumentEdit` + stale baseline guard (если буфер изменился после открытия preview — отказ и просьба обновить).

## Properties-панель (план 04)

- Правый inspector: вкладка «Свойства» (`list.bullet.rectangle`) — frontmatter текущего документа как форма. Ядро `Editor/FrontmatterEdit.swift`: построчные `replace/insert/remove` + list, без YAML-сериализатора; complex / duplicate / multiline → отказ (Source only).
- Типы: string / number / bool / date / tags / aliases / list / complex. Коммит string/number — Enter или blur; bool/date — сразу; списки — чипы + add/remove item. Undo через `MarkdownDocument.applyDocumentEdit` (тот же путь, что plugin-card).
- **Поведенческое:** frontmatter в Visual и Preview **по умолчанию свёрнут** (editing живёт в панели). Disclosure-toggle session-local как раньше; отдельный Settings-switch не добавлялся.
- Preview plugin-card по-прежнему редактирует whitelisted поля multi-checkbox; панель — произвольные простые top-level поля (двойной UI допустим).

## Мелочи и доводка сайдбаров (план 08)

- **8.1 — встроенные шаблоны:** общий flow «Новый файл…» в контекстном меню и карточке папки предлагает Пустой / Заметка / Встреча / Проект / Исследование / Ежедневная заметка. Шаблоны скомпилированы в Swift, подставляют локальную дату и имя файла, а daily использует `YYYY-MM-DD.md` и открывает существующий файл без перезаписи. Нижний `+` Files остался folder-only: он не имеет однозначного каталога назначения.
- **8.2 — избранное:** Files показывает per-workspace секцию избранных документов (до 50 на корень), сохранённую рядом с остальным `WorkspaceModel` state. Недоступность проверяется off-main; исчезнувшая строка остаётся видимой и удаляется только кликом пользователя. Успешные file move и root rename мигрируют favorite path вместе с остальным path-keyed state.
- **8.3 — Review справа:** Review удалён из workspace navigator и добавлен в document inspector с прежним фильтром и счётчиком открытых меток. Старый `sidebarTab=review` мигрирует в `sidebarTab=files` + `inspectorTab=review`; Preview/Split compose открывает правую панель. Модель Review и её FIFO persistence не менялись.
- **8.4 — callouts:** top-level `> [!type]` распознаётся общей offset-safe функцией. Source выделяет marker, Visual несёт type как presentation metadata обычной цитаты (цветная полоса + SF Symbol), Preview выдаёт `callout-*` class/icon с light/dark CSS. Неизвестный type сохраняется и использует стиль note; nested/list/foldable формы остаются обычными цитатами. Visual сохраняет soft line breaks callout через отдельный semantic attribute, поэтому canonical source round-trip остаётся байт-в-байт.
- **8.5 — нормализация строк:** Info предлагает явную undoable-команду только для буфера с CRLF/CR/mixed endings или без финального newline. Команда приводит все разделители к LF и добавляет финальный newline через `MarkdownDocument.applyDocumentEdit`; обычный save по-прежнему пишет исходные байты текста без неявной нормализации.

## Frontmatter только в панели «Свойства» (после планов 01–08)

- **Поведенческое:** YAML frontmatter полностью убран со страницы. Preview не рендерит properties-карточку (удалены `frontmatterPropertiesHTML`, disclosure-JS, plugin-card HTML/JS/CSS и `BuiltInPluginConfigurationHandler`); Visual больше не эмитит `.raw`-остров.
- Round-trip Visual: рендер пропускает блок, координатор кэширует verbatim-блок (`frontmatterBlock`) при каждом `loadDocument` и препендит его в `syncToDocument` через чистую `composeDocumentWithFrontmatter` (fm + `\n\n` + body — тот же normal form, что давал старый остров + separator). `paragraphRanges` сдвигаются на длину префикса, так что display↔markdown-карты остаются в координатах документа. Следствие: ⌘A+Delete в Visual больше не удаляет frontmatter (модель Obsidian).
- Плагины: карточка настройки multi-checkbox стала нативной в панели «Свойства» (`PluginChecklistCardView` / `PluginStateRowView` в `PropertiesPanel.swift`) — marker/название/иконка (SF/emoji/текст)/зачёркивание, «+ Состояние», диагностика invalid-конфига. Путь применения тот же whitelist: `BuiltInPluginRegistry.updateConfiguration` → `applyDocumentEdit`. Новый лёгкий API `checklistCards(in:)` (frontmatter-only, без token scan) — можно звать из SwiftUI body.
- Кнопка добавления плагина переехала из action strip в панель «Свойства» (меню «+ Плагин»); из strip удалён `pluginMenu` и его width-key, из `ContentView` — wiring. Ключ `editmd` скрывается из списка полей, когда есть карточки/диагностики.
- Интерактивные чекбоксы multi-checkbox в теле Preview не тронуты (`builtInPluginToggle` остался). Gate `hasEditablePreviewFocus` удалён — единственным editable-контентом Preview была plugin-card.

## Локализация EN/RU (String Catalog)

- Полный перевод UI на канонический механизм Apple: development language `en`, каталог `Resources/Localizable.xcstrings` (~590 ключей, только ru-переводы — en живёт ключами). Все русские литералы в коде переписаны на английские; plain-String контексты (NSAlert, NSMenuItem, панели, статусы моделей, LocalizedError) обёрнуты в `String(localized:)`; SwiftUI-литералы (`Text`/`Button`/`Section`/…) остались ключами как есть.
- Охват: меню и команды, настройки, все сайдбары, welcome, PDF/image viewer, lint-сообщения (`MarkdownLint`, `VaultLint`), review (метки, статусы очереди, тред-ответы), шаблоны новых файлов (`FileTemplates` — заголовки секций локализованы, YAML-ключи нет), диалоги git/push, SkillInstaller. Протокольные строки MCP/control-socket и логи не локализуются.
- Плюрализация — через variations в xcstrings (файлы/варианты/документы/ошибки/предупреждения). Ловушка: два `%lld` в одном ключе не дают вывести аргумент plural-вариации — такой ключ переписан без склонения. Вторая ловушка: `Int32` в интерполяции даёт `%d`-ключ, а не `%lld` — кастовать в `Int` (ReviewSidebar exit code).
- Переключатель: Settings ▸ General ▸ Language (`AppLanguage.swift`) — Automatic/English/Русский; пишет app-domain `AppleLanguages` + зеркальный ключ `editMD.languageOverride` (по «сырому» `AppleLanguages` нельзя понять, есть ли override — global domain всегда непуст), применяется после перезапуска. Хелперы настроек (`ValueSlider`, `FontSizeStepper`, `FontFamilyPicker`, `ColorOverrideRow`, `elementRow`) переведены на `LocalizedStringKey`.
- Тесты: scheme test action получил `-AppleLanguages (en)` — тест-хост всегда en, ассерты на UI-строки пишутся по-английски (иначе на русской macOS `String(localized:)` в app-таргете вернул бы перевод). Ручной рукописный ru-плюрализатор в `WorkspaceSearchSidebar`/`FolderInfoActions` удалён в пользу каталога.

## Темы Preview (первый срез концепта тем)

- **Концепт:** тема = визуальный характер markdown (типографика + цвета + декорации), а не палитра-скин. Первый срез — только Preview: Source/Visual и их `EditorTheme` не тронуты; фон страницы и базовый цвет текста темы не задают (Canvas/CanvasText остаются системными, override General ▸ Text обязан побеждать). Решения пользователя: старые скины (nord/solarized/dracula) при будущей унификации убрать, фон не трогать.
- Механика: `PreviewTheme` (`Editor/PreviewTheme.swift`) — compiled-in каталог (default/minimal/literary/academic/technical), каждая тема = `bodyFontStack?` + CSS-слой. Слой вставляется в `previewHTMLPage` между базовыми правилами (включая их dark-media блок) и пользовательским elementCSS: каскад даёт precedence base < theme < user при равной специфичности. PDF-экспорт наследует тему тем же параметром `themeCSS`.
- Ключевая развязка: elementCSS больше не эмитит дефолтные значения `ElementStyles` (раньше h1–h6 всегда получали font-size/weight и перебивали бы любую тему). Дефолты перенесены в базовые правила страницы (h1 1.8em/700 и т.д. — визуально идентично прежнему рендеру), эмитится только отличие от дефолта. Тесты, ожидающие эмиссию, должны задавать не-дефолтные значения.
- Гочи тем: `blockquote { border-left: none }` темы убивает и полосу callout'ов (у базового `.callout` только `border-left-color`) — тема обязана вернуть `blockquote.callout { border-left: 4px solid rgb(var(--callout-rgb)) }`. Тёмные цвета хекс-тем — через собственный `@media (prefers-color-scheme: dark)` блок (не `light-dark()` — деплой macOS 13). Academic возвращает display-математике центрирование, перебивая лево-выравнивание базы.
- Хранение: id темы в `PreviewTypographySettings.theme` (`decodeIfPresent` → `"default"` для старых prefs), выбор — Settings ▸ Preview ▸ Theme. Шрифт: пустой user `fontFamily` → стек темы (`cssFontFamily(userFamily:)`), явный выбор пользователя всегда побеждает.
- UI-доступ: палитра-меню тем Preview живёт в action strip режима Preview (группа `theme` в `EditorActionStrip`, только `.preview`; во «…»-overflow флэттенится в пункты с чекмарком). Из window-тулбара убраны Cut/Copy/Paste и старое меню-палитра `EditorTheme` — пресеты Source/Visual выбираются только в Settings ▸ General.
- Правка `.xcstrings` руками: не пересериализовывать файл питоновским `json.dump` (другая сортировка/формат `" : "` — диф на тысячи строк); вставлять блоки текстово в отсортированную позицию (сортировка Xcode case-insensitive).
- **Тема `typora` (2026-07-23):** портрет дефолтной пары тем Typora из typora/typora-default-themes: свет = «Github», тьма = их тёмный дефолт «Night» — два разных дизайна, не перекраска. Светлая часть — прямые токены github.css: стек Open Sans/Clear Sans/Helvetica Neue, bold-заголовки (h1 2.25em, h2 1.75em) с линиями #eee без padding-bottom, ссылки #4183C4, инлайн-код с рамкой #e7eaed на #f3f4f4 (radius 3px), панели кода #f8f8f8, цитата — серый текст #777 без заливки/радиуса (callout возвращает `color: inherit`, заливку даёт база), таблицы с полной обводкой #dfe2e5, покрашенным thead и чётной зеброй #f8f8f8, hr — 2px полоса #e7e7e7. Тёмный `@media`-блок — структурный порт night.css (сверен по HTML-экспорту живой Typora в docs/typora): normal-weight заголовки «Lucida Grande»/Corbel в rem-размерах без линий h1/h2, ссылки #e0e0e0 с подчёркиванием, body-шрифт переключается на Helvetica Neue, отступная цитата с 2px #474d54, инлайн-код Monaco на rgba(0,0,0,0.05) без рамки, панели #333 с отступом 10/30, hr #474d54, таблицы #474d54 5px/10px без зебры, маркеры square, strong/th #DEDEDE. Фон Night #363B40 сознательно НЕ портирован (решение «фон не трогать»).
- Ревью-фиксы temы typora (после codex-ревью 5b6f6ac): (1) dark-блок переделан из перекраски Github в порт Night (выше); (2) Open Sans реально бандлится — woff 400/400i/700/700i из той же репы Typora лежат в `Resources/opensans/` (Apache 2.0, `opensans-LICENSE.txt`) и встраиваются в CSS темы data:-URI (CSP страницы разрешает только `font-src data:` — внешний URL не загрузился бы; unicode-range латиница как у Typora, кириллица честно падает в Helvetica Neue); (3) референсная геометрия: `PreviewTheme` получил `preferredFontSize/preferredColumnWidth` (+`darkBodyFontStack`, `fontFacesCSS`, `pageCSS(userFamily:)`), применяются ТОЛЬКО пока пользовательское значение равно стоковому дефолту Preview (`EditorSettings.previewDefaults()`, 15pt/736) — typora даёт 16px/860 из github.css; явный выбор пользователя всегда побеждает, включая «0 = полная ширина». Гоча ресурсов: сборка сплющивает подпапки `Resources/*` в корень bundle — файлы ищутся subdirectory→flat (как KaTeX), а имена ресурсов должны нести префикс (`opensans-400.woff`, не `400.woff`).

## Спринт 1 «гигиена и быстрые победы» (0.43.0)

Первый спринт после разбора бэклога (`docs/todo.md`). Пять пунктов, из них один — продуктовое решение без кода.

- **Удалён `yamlLineSegments`** и его приватные хелперы (`appendContentSegments`/`appendValueSegments`/`classifyScalar`, enum `YAMLTokenKind`) из `Frontmatter.swift` — после скрытия frontmatter со страницы у токенизатора не осталось потребителей в app-коде. Общие хелперы (`isYAMLNumber`, `keyColonIndex`, `trailingCommentIndex`, `splitFlowList`, `unquote`, `leadingWhitespaceCount`) остались — их делит `FrontmatterEdit`/Properties. Удалены и 5 тестов токенизатора.
- **Workspace-закрепление — решено оставить как есть** (продуктовый вопрос, не код). Одиночный файл из Finder вне adopted-папки остаётся session-only loose (закрепление вручную пином); workspace-папки уже персистятся. Отклонены авто-запоминание файла (LRU-пин) и авто-усыновление родительской папки.
- **Paste URL → ссылка** (`Editor/PasteLink.swift`): голый http(s)-URL в буфере, вставленный поверх непустого выделения, оборачивает его в `[выделение](url)`. Чистые хелперы `bareWebURLForPaste` (консервативный: одна строка, http/https, есть host, без пробелов) + `markdownLinkSyntax` (эскейпит `]` в лейбле, угловые скобки для URL со скобками/пробелами). Новая **последняя** дверь в обоих funnel'ах (`handleSourceSpecialPaste`/`handleVisualSpecialPaste`) — после table/image, перед plain text; в Visual рендерится через `renderForInsertion`, guard контекста (не codeBlock/tableCell/raw). Только paste-время — живой линкификации нет, поэтому удаление форматирования не возвращает его.
- **Столбцы таблиц в strip**: меню Table в action strip получило Add/Delete Column (раньше только строки). Source и контекстное меню Visual уже имели полный набор — добавлены `tableAddColumn`/`tableDeleteColumn` в `FormatActions`/`EditorStripActions`, координаторные методы через существующий `performTableOp` (native) / `mutateTableIsland` (island), покрывают оба вида таблиц. Столбцы остаются Visual-only.
- **Per-document режим редактора** (идея FSNotes `previewState`): `Views/EditorModeStore.swift` — словарь путь→mode в UserDefaults (`editorMode.byPath`, soft-cap 2000, path стандартизуется, `defaults` инъектируемый). ContentView восстанавливает режим в `.onAppear`/`.onChange(of: fileURL)` через `setEditorMode`, записывает в нём же. Глобальный `@AppStorage("editorMode")` остаётся дефолтом для невиданных файлов и untitled. Следствие: «страничные» заметки открываются в Preview, черновики — в редакторе. **(Отменено — см. ниже «Режим редактора: session-sticky».)**
- **Режим редактора: session-sticky, сброс в Preview на каждом запуске** (427e4cf, отменяет per-document выше): по продуктовому решению пофайловой памяти режима больше нет — режим общий на сессию. `EditorModeStore` и его тесты удалены, `restoreModeForCurrentFile` и запись `setMode` вырезаны из ContentView. Модель: холодный старт → Preview (read-first); переключение режима липнет через `@AppStorage("editorMode")`, но только в пределах запуска; перезапуск снова даёт Preview. Реализация — `resetEditorModeForColdLaunch(_:)` (свободная функция рядом с `editorModeOverride`, вызывается из `applicationDidFinishLaunching`): пишет `editorMode`=preview и чистит orphaned `editorMode.byPath`. `.created`→Visual и `.finder`→Preview без изменений; на холодном старте оба пути садятся на Preview без гонки launch-order. Хелпер, тест `coldLaunchResetsToPreview` (suite `Editor mode open rules`) и byPath-cleanup — в 0c5a6a2 (polish поверх продуктового 427e4cf).

## Спринт 2 «корректность round-trip и формул» (0.44.0)

Три известных дефекта сериализации Visual; два починены, третий зафиксирован как ограничение.

- **Loose-списки сохраняются** (был: нормализовались в tight). Открытие документа в Visual молча переписывало список с пустыми строками между пунктами в плотный — портило реальные файлы (CLAUDE.md терял пустые строки) и шумело в git-diff. EditMD рендерит loose и tight ОДИНАКОВО (HTML-рендерер всегда unwrap'ит первый параграф пункта), поэтому это чисто байтовая неверность, не презентационная. Детект loose на рендере: swift-markdown не отдаёт tight/loose, а по source-ranges tight и loose неотличимы (loose-пункт поглощает завершающую пустую строку, gap = 1 в обоих случаях) — поэтому проверяется, пустая ли строка ПЕРЕД началом пункта в `parseSource`. Флаг `loose` на `MDBlock` (O(1) hash), сериализатор `separator` эмитит пустую строку между siblings ОДНОГО уровня; цитаты-вложенные списки и шаг parent→child остаются tight.
- **`\$` переэскейпливается**. Экранированный `\$x\$` (литеральные доллары) терял бэкслеши через Visual round-trip: cmark разэскейпливает `\$`→`$`, а `escapeInline` не эскейпил `$` обратно — при следующем парсе math-сканер снова съедал `$x$` как формулу. Теперь `escapeInline` гоняет `scanMathSpans` по тексту рана и эскейпит `$` только у спанов, которые сканер РАСПОЗНАЛ бы как формулу (реальная математика хранится отдельными `.mdMath`-ранами и сюда не доходит). Валюта (`$5`, `$20 and $30`) не эскейпится — одиночные `$` и currency-guard сканера их не трогают.
- **Многострочный `$$…$$` в blockquote — известное ограничение**. `MathScan.matchDisplay` отклоняет display-спан, пересекающий `>`-строку (маска затёрла бы `>` и сломала структуру цитаты). Корректный фикс требует переработки masking-инварианта (сохранять `> `-префиксы, менять verbatim-хранение `.mdMath` в трёх рендерерах + сериализаторе) — непропорционально риску для очень редкого кейса. Деградирует мягко: многострочный `$$` схлопывается в литерал `> \$\$ … \$\$` без потери контента, идемпотентно. Однострочная inline/display-математика в цитате (`> $E$`, `> $$E$$`) работает. Pin-тест фиксирует деградацию от тихой регрессии.

## Спринт 3 «темы, этап 2 — чистка» (0.45.0)

Изначально план был на полную унификацию (ThemeSpec → проекции на Preview/Visual/Source, фон-«бумага» во всех режимах). Пользователь переопределил объём (2026-07-18): «старую удали, потом сделаем пресеты для source и visual». Полная унификация и фон отложены; сделана чистка второй, избыточной оси тем.

- **Удалена старая система `EditorTheme`-пресетов.** До этого было ДВЕ независимые оси: `PreviewTheme` (типографика Preview, палитра в strip) и `EditorTheme` через `general.themePreset` (цвета текста/кода Source+Visual, пикер в Settings ▸ General). Вторая — наследие, её скины Nord/Solarized/Dracula/Sepia/System/High Contrast были просто цветовыми вариантами и путали (два разных места выбора «темы»).
- Удалено: пикер «Preset» из GeneralTab, статики `system/sepia/nord/solarized/highContrast/dracula`, `allPresets`, `preset(named:)`, поле `GeneralSettings.themePreset` (со всеми call-site'ами). `EditorTheme` сжат со ~360 до ~178 строк — остался единственный облик `editorDefault` (= бывший `github`, адаптивный light/dark через `gh(...)`).
- Секция Settings ▸ General ▸ «Theme» переименована в «Appearance» — теперь только выбор light/dark/system. Base-цвета (text/accent override) и `applyingOverrides` сохранены. `effectiveTheme` = `editorDefault.applyingOverrides(general)`.
- Миграция: старые prefs с `themePreset` декодируются мимо (поле удалено из Codable, `decodeIfPresent` больше не зовётся) — любой прежний выбор скина молча становится дефолтным обликом. Приемлемо (решение пользователя «с миграцией»).
- **Отложено на потом:** полноценные пресеты Source/Visual поверх baseline (возможно ThemeSpec + семантические токены), единый пикер, `ElementStyles`/`fontFamily` fallback'и в тему, «Reset to theme», фон-«бумага». Фон Source/Visual по-прежнему НЕ трогается (системный Canvas).

## Спринт 4 «изображения» (0.46.0)

Две фичи из давних «известных хвостов» CLAUDE.md, обе переиспользуют существующую инфраструктуру вставки картинок (`storeImageAsset`, `ImageInsertionAsset`, `imageCandidate(from:)`).

- **Drag-and-drop изображений в Source и Visual.** Файл из Finder или битмап, брошенный на редактор, проходит тем же путём store+insert, что paste/кнопка: сохраняется в `assets/`, вставляется как `![](assets/...)` в точке дропа. Оба NSTextView-сабкласса (`SourceNSTextView`/`VisualNSTextView`) переопределяют `draggingEntered/Updated/prepareForDragOperation/performDragOperation`; `imageCandidate(from: sender.draggingPasteboard)` решает, картинка ли это, иначе `super` (обычный текст-дроп работает). Дроп-точка через `characterIndexForInsertion(at:)`; курсор двигается в `draggingUpdated` для фидбэка. Новый метод координатора `insertDraggedImage(_:)` в обоих (Source чтит fence-guard, Visual — `visualContextAllowsStructuredPaste`). Общий список drag-типов `imageDragPasteboardTypes` регистрируется поверх собственных типов вью (`registeredDraggedTypes + …`). Тест: file-URL паствборд → `.file` кандидат, не-картинка → nil.
- **Remote (`http(s)`) images в Visual.** Раньше схемные URL всегда давали placeholder (`resolveImageURL` резолвил только document-relative пути). Теперь `RemoteImageCache` (`Editor/RemoteImageCache.swift`, `@MainActor`-синглтон): сессионный in-memory кэш `[URL: NSImage]`, дедуп in-flight запросов (несколько картинок с одним URL = одна загрузка), 20MB cap. Загрузка off-main через `URLSession.shared.data` (nonisolated `fetchData` возвращает `Data` — Sendable; декод `NSImage` на main). `attachment(forSource:)` для remote ставит placeholder и стартует async; по приходу свапает картинку в ТОТ ЖЕ attachment-объект и рефлоит только раны этого src (`invalidateLayout(forCharacterRange:)`), не весь документ. Guard `imageAttachments[src] === attachment` защищает от позднего колбэка после ре-рендера. Приватность: каждый remote-src = сетевой запрос к произвольному хосту — но Preview это уже делает (CSP `img-src http(s)`), так что Visual консистентен; не гейтим.

## Спринт 5 «поиск внутри Preview» (0.47.0)

Последний давний «известный хвост». ⌘F в полном режиме Preview: до этого меню Edit ▸ Find слало `performTextFinderAction` в responder chain, а WKWebView его не отвечает — в Preview поиск молча ничего не делал.

- **Маршрутизация меню.** `ContentView` держит `@StateObject previewFind: PreviewFindModel` и публикует focused value `previewFind: PreviewFindActions?` **только** пока `mode == .preview`. `EditMDApp` читает `@FocusedValue(\.previewFind)`: если непусто — Find…/Next/Previous/Use-Selection идут в Preview-модель, иначе падают на нативный `sendFindAction` (Source/Visual так и остаются на `NSTextFinder`). Find-and-Replace в Preview выключен (read-only) — всегда нативный путь. Так «связь с существующей моделью поиска» = те же пункты меню и те же горячие клавиши (⌘F/⌘G/⌘⇧G/⌘E), а не общий Swift-движок (его для in-editor find нет; `SearchQuery`/`SearchMatch` — это workspace-поиск плана 07, другое).
- **JS-слой.** `PreviewHTMLPage` получил `window.editMDFind(query)` / `editMDFindStep(delta)` / `editMDFindClear()`. Поиск — case-insensitive substring (дефолт NSTextFinder), совпадения оборачиваются в `<span class="editmd-find">` через split текст-нод (собираем ноды в массив ДО мутации, каждую бьём один раз; матч не пересекает границу инлайн-элемента — то же ограничение, что у нативного find на rich text). Текущее совпадение — класс `editmd-find-current` + `scrollIntoView(center)`. Clear разворачивает спаны и `normalize()`. CSS-классы (мягкий жёлтый + оранжевый current, обе палитры) — в шелле.
- **Swift драйвит каждый поиск.** `MarkdownPreviewView.Coordinator.performFind/performFindStep/performFindClear` зовут JS через `callAsyncJavaScript` и парсят `{count, index}` обратно в модель (`report`). Fragment swap (`editMDReplacePreview`) и полный reload выкидывают старые спаны — JS сбрасывает `findMatches=[]` при swap, а Swift переигрывает активный запрос (`reapplyFindIfActive` после applyFragment и в `didFinish`). Единый источник истины — Swift; JS сам не переигрывает, чтобы не задваивать. `editMDFind` сохраняет текущий ординал, если матчей не меньше (типизация в Preview матч не теряет).
- **UI.** Плавающий `PreviewFindBar` (`.regularMaterial`, top-trailing overlay поверх Preview, под action strip): лупа, поле, «N из M» (или «Не найдено»), ↑/↓, ✕ (⎋). Enter = next. `@FocusState` + `focusRequest`-счётчик даёт фокус полю при ⌘F. Бар закрывается при уходе из Preview (`setEditorMode`) и смене файла. Query переживает close (реоткрытие восстанавливает последний поиск). Full Preview имеет `reverseScrollEnabled == false`, так что программный скролл к матчу не улетает обратно в редактор.
- Тесты: `testPreviewPageIncludesFindLayer` (наличие функций/классов + сброс после swap), `PreviewFindModelTests` (переходы состояния модели на recording-closures — search/clear/step-guard/activate/use-selection/close). Глазами не проверено.

## Редактор ссылок и фикс paste-URL (0.47.1)

Жалоба пользователя: «вставка url и автоформатирование как ссылки не работает» + «сделай редактор ссылок». Probe-тест реального `SourceNSTextView.paste` показал, что paste-URL **над выделением** работает (`[sel](url)`); ломался случай **без выделения** — вставлялся голый URL, а рендерер его НЕ автолинкует (probe: `Only https://…` → plain span, тогда как `<https://…>` и `[url](url)` → `<a>`). То есть с точки зрения пользователя ссылка не получалась.

- **Фикс paste без выделения.** `linkifyPastedURL` (Source) и `pasteURLLinkFromPasteboard` (Visual) больше не требуют непустого выделения: при пустом выделении вставляют автолинк `<url>` (кликабельный, round-trip), при непустом — по-прежнему `[selection](url)`. Общий `markdownAutolinkSyntax(url:)` в `LinkEdit.swift` (fallback на `[url](url)`, если в URL есть `<`/`>` — в CommonMark-автолинке они невалидны; детектор и так гарантирует отсутствие пробелов). Fence-контексты Source/Visual по-прежнему уходят в plain (guard'ы не тронуты). Порядок дверей funnel не изменился — URL-дверь последняя перед plain.
- **⌘K редактор ссылок в Source.** Раньше `Add Link…` (⌘K) был жив только в Visual (там `editLink` через `.mdLink` на attributed). Теперь Source публикует `editLink` в `FormatActions` и правит raw markdown: `inlineLinkMatch(in:at:)` находит `[text](dest)` под кареткой через swift-markdown AST (`LineIndex.offset` → NSRange; каретка на любом крае спана считается «внутри»; автолинк `<url>` тоже матчится → ⌘K конвертит его в `[url](url)`). Apply пишет `markdownLinkSyntax`, Remove заменяет спан на его label.
- **Общий диалог.** NSAlert с двумя полями (text + URL) и кнопками OK/Cancel/(Remove Link) вынесен в `runLinkEditPrompt(existingText:existingURL:) -> LinkEditResult` в `LinkEdit.swift`. Visual `editLink` отрефакторен на него (минус дублирование), Source использует тот же. Меню `Add Link…` остаётся `⌘K`, `editLink != nil` теперь и в Source → пункт активен в обоих редакторах; заголовок диалога сам меняется Add/Edit.
- Тесты: `LinkEditTests` (autolink-сериализатор + `inlineLinkMatch` по кареткам/краям/автолинку/plain), `SourcePasteURLIntegrationTests` (реальный `paste`: над выделением → `[..](..)`, без выделения → `<url>`, не-URL → plain). Глазами не проверено (диалог NSAlert headless не гоняется).

## CPU-сага LinkIndex/vault-lint (0.47.2–0.47.3 + продолжение 2026-07-19)

Жалоба «>100% CPU минутами» на WoL-вольте (~7000 md, 47 МБ). Метод поимки — watcher-скрипт, снимающий `sample <pid> 3` при устойчиво высоком CPU. Серия фиксов:

- **Квадратичный line lookup** — `lineNumber(utf16Offset:)` шёл от начала буфера на каждый линк; теперь бинарный поиск по `LineIndex` (218a5f5).
- **Parse-кэш** — `FileScanEntry` по `(mtime, size)` переживает `invalidate()`; повторный скан перечитывает только изменённые файлы (e94fd84).
- **Vault-lint по требованию** — полный прогон только для панели отчёта (`runNow()`/reportActive), редакторы берут per-file `vaultLintFindings(for:)` из shared-каталога на ревизию индекса; `LinkIndexSnapshot(standardizedOutgoing:)` trusted-init без re-standardize/stat на main (8e0c167 + ревью-фиксы 91aee49, 68e44be).
- **Чип прогресса** — «Indexing links… N%» в статус-баре: `scanProgress` двухфазный (parse 0…0.5, resolve 0.5…1), `StandaloneActivityBar` для окон без документа (9a40b9f). Чип же и вскрыл, что full scan рестартовал постоянно.
- **Ложные рестарты скана** (72300f6): same-key `ensureIndex` (onAppear каждого открытия файла) переиспользует in-flight скан через `inFlightKey`; агентская запись существующего файла не бампает epoch (инкрементальный путь и так реиндексирует файл).
- **Прогрев на старте** (2ae0064): `applicationDidFinishLaunching` запускает первый скан, пока пользователь на welcome-странице (не под XCTest).

### Контракт linkEpoch

`WorkspaceModel.linkEpoch` — отдельный от `contentEpoch` ключ линк-графа. Бампается: (1) на реальные мутации ФС через `noteFilesystemChange` (create/delete/rename/агентская запись НОВОГО файла); (2) на активацию приложения через `refreshLinkGraphAfterActivation` — внешние правки ЗАКРЫТЫХ файлов иначе не попадали в индекс вовсе (ревью-фикс: 72300f6 сначала совсем убрал инвалидацию по активации, но «следующего триггера» могло не быть). Активационный бамп выполняется сразу только при `hasCompletedFullScan && !isScanning`: смена ключа отменяет in-flight скан, а отменённый скан не публикует частичный кэш — рестарт выбрасывал бы минуты работы. Активация ВО ВРЕМЯ скана не теряется, а откладывается (`deferActivationRefresh` — скан мог уже прочитать файл до внешней правки): завершившийся скан переигрывает `refreshLinkGraphAfterActivation` после обработки `scanPending`, так что если там стартовал новый скан — refresh откладывается снова, иначе ре-ключует немедленно. Полностью холодный индекс (никто не строил и не строит) активацию игнорирует — lazy-модель. Активация считается «возвратом из background» только после `didResignActive` (`wasBackgrounded` в `handleAppActivation`): внешний редактор может тронуть файлы, только пока EditMD не frontmost, а ПЕРВАЯ активация процесса прилетает сразу после запуска, пока идёт warm scan, — без этого гейта каждый cold launch выполнял два полных скана подряд. Правки открытых файлов идут инкрементальным путём `noteDocumentPersisted` без бампа. Благодаря parse/resolve-кэшам rebuild по активации без изменений на диске = walk + stat'ы, не ре-парс.

### Resolve-кэш и его границы

`FileScanEntry.resolvedLinks` + `resolveFingerprint` (7b9685b): резолв зависит от того, какие файлы существуют, а не от их содержимого — неизменённый файл при неизменённом окружении пропускает resolve-пасс целиком. Fingerprint (XOR-хэш, process-local) покрывает roots + wiki-индекс + **полный набор видимых путей под roots из walk-фазы** (`ResolveEnvironment.paths`) — последнее добавлено ревью-фиксом: `resolveLocalLinkDestination` принимает ЛЮБОЙ существующий путь (каталог, csv…), а исходный fingerprint видел только wiki-индексируемые файлы, и `[reports](./reports)` оставался dead после создания каталога. Правила:

- Full scan обязан видеть диск «сейчас»: перед снятием wiki-снапшота `WikiLinkResolver.shared.invalidate()` (его built-кэш иначе отдавал устаревший индекс при неизменных roots, и fingerprint не менялся).
- Кэшируется только резолюция, полностью покрытая окружением (`localResolutionCovered`): каждый кандидат probe до первого хита лежит в walked-каталоге под видимым именем. Цели вне roots, скрытые имена, содержимое package'ей, symlink'и — не кэшируются и ре-резолвятся каждый full scan (walk их не видит, fingerprint не заметит изменение). `localLinkDestinationCandidates` вынесен из `resolveLocalLinkDestination`, чтобы coverage-проверка зеркалила порядок probe.
- Single-file путь (`rescanSingleFile`) не пишет resolve-кэш и не инвалидирует wiki-индекс (авто-сейв должен оставаться дешёвым).

### Индекс скоупится на активный workspace

По просьбе пользователя автоматическая индексация покрывает ОДИН workspace — владельца активного документа (`WorkspaceModel.linkIndexRoots`; fallback — первый workspace, он же стартовая ветка запуска). Раньше `ensureIndex` сканировал все adopted workspaces разом: launch/rebuild стоил сумму всех вольтов, хотя backlinks и vault-lint — вопросы «внутри вольта» (Obsidian-семантика: vault = единица резолюции; кросс-workspace wiki-таргеты и так были неоднозначны). Механика:

- `noteActive` (открытие файла в главном окне) дёргает `LinkIndex.noteActiveDocumentChanged` — lazy no-op, если индекс никто не строил; смена файла внутри workspace — no-op по same-key; смена workspace меняет ключ → рескан нового workspace.
- `scanCache` переживает переключение: публикация скана заменяет записи только ПОД отсканированными roots (отсутствие = удалённый файл), записи чужих workspaces сохраняются — возврат в workspace это walk + stat'ы, без ре-парса и ре-резолва (fingerprint для прежнего окружения совпадает).
- Wiki-индекс full scan'а строится по активному root'у; `navigateToWikiLink` по-прежнему резолвит по всем workspaces (user-driven переход не тронут).
- Следствие контракта: published `outgoing`/`backlinks`/vault-lint отражают только активный workspace; кросс-workspace backlinks в индексе не существуют.

Осталось дорогим только: полный ре-резолв после add/remove/rename файла (корректно: новый файл может перехватить wiki-таргеты); первый скан за запуск закрыл персист индекса (план 10 ниже). Глазами серия 2026-07-19 не проверена.

## «wikillm ready» — план 10 (2026-07-19)

Термин пользователя: агент работает с wikillm-вольтом (Karpathy-паттерн компилируемой wiki; WoL — вариация) через EditMD, а не обходит вольт сам. Полный план и решения — `docs/plans/10-wikillm-ready.md`. Итог четырёх этапов:

- **Персист индекса** — `<workspace>/.editmd/link-index.json`: атомарная запись off-main после успешного full scan активного workspace, seed `scanCache` на холодном старте (неизменный вольт = walk+stat'ы, 0 ре-парсов/0 ре-резолвов). Каталог само-игнорируется (`.editmd/.gitignore` = `*`). Fingerprint переведён на стабильный FNV-1a по ОТНОСИТЕЛЬНЫМ путям (переживает перезапуск и перенос вольта; `Hasher` с process-seed непригоден). `mtime` хранится bitPattern'ом `timeIntervalSinceReferenceDate` — decimal-JSON round-trip не bit-exact, а промах молча убил бы seed. Decode = untrusted input: чужая версия/битый JSON → пустой seed; `..`-escape и абсолютные пути отбрасываются. Lite/loose файлы `.editmd/` не создают.
- **Команды vault-графа в control socket** (`ControlLinkCommands.swift`): `links.outgoing/backlinks/resolve`, `outline`, `lint.workspace/file`, `index.status`, `tags.list/files`, `frontmatter.get`, `search`. Контракты: скоуп = активный workspace (`outside-active-workspace`); команда = consumer индекса (kick + «indexing N% — retry», завершённый индекс НЕ перезапускается — тесты сидируют `LinkIndex.shared`); диск только в deferred-фазе; findings — структурный payload, не локализованный текст; resolve бриджит actor bounded-семафором (socket-потоки выделенные). IDE MCP `tools/list` НЕ расширяется — CLI обрывает handshake на незнакомых инструментах.
- **Offline-движок** — вместо headless-запуска GUI чистое ядро вынесено в Editor/ (`LinkGraphEngine` из LinkIndex, `WikiLinkCore` из WikiLinkResolver, `LineIndex` из MarkdownHighlighter, `ImageFileTypes` из PDFViewerView, `TagScan`, `homeDocument` → VaultLint; app-only мост — `VaultLintSourceBridge`) и компилируется в target `editmdctl` (список файлов в `project.yml` обязан оставаться AppKit-free). Wire-шейпы — один общий `ControlGraphPayload.swift`. `OfflineVault` + автофоллбэк по отсутствию сокета; offline-ответ = правда диска (seed → walk → resolve по fingerprint-кэшу → save); `index rebuild` offline-only и отказывается при живом app; root: `--root`, маркеры `.editmd`/`.obsidian` вверх, явный root авторитетен (свежий вольт без маркера).
- **Гоча, пойманная offline-smoke и жившая и в app**: `contentsOfDirectory(at:)` отдаёт детей с резолвнутым `/private/…`-префиксом при корне `/var/…` — сырые пути в `ResolveEnvironment` не совпадали со стандартизованными кандидатами, и ссылки в ПОДКАТАЛОГИ (`[c](notes/x.md)`) молча не кэшировались резолвом. Окружение стандартизуется при сборе; инвариант — `testCoverageForSubdirectoryRelativeLink`.
- **Skill** — раздел «Vault graph (wikillm)» в SKILL.md (правило «ask EditMD, don't walk the vault», маршрутизация socket/offline), таблица команд и формат индексного файла в reference.md (opaque-поля не считать самому), рецепты, intent «Work the vault graph» в prompts.md + ✨-палитре (`vault-graph`).

## Навигация Back/Forward с восстановлением позиции (2026-07-20)

Движок `DocumentHistory` (задел v25) доведён до полноценной навигации и выведен в UI.

- **Видимая кнопка.** Браузерные шевроны ‹ › в `MainChrome` (`.navigation`-плейсмент, рядом с тумблером сайдбара), disabled-состояние из `canGoBack/canGoForward`. Раньше Back/Forward были только в меню View (⌘[ / ⌘]).
- **Восстановление позиции.** История хранит `Visit { url, offset }` вместо голого `[URL]`. Оффсет каретки снимается с `EditorPositionStore.markdownOffset` активного main-редактора через `currentOffsetProvider` (main `ContentView` ставит его в `.onAppear`; view `.id`-recreated per file, поэтому замыкание всегда указывает на текущий store). Момент снятия — уход с записи (новый переход ИЛИ шаг Back/Forward, чтобы обратный шаг вернул туда же). Восстановление едет по существующему control-jump пути (`requestControlJump` → `consumePendingControlJump`). Dedup при возврате: `record` не пере-штампует запись, на которую только что пришли (index уже стоит на цели → `openInMainWindow`'s `recordVisit` — no-op).
- **Мышь.** Боковые кнопки (buttonNumber 3=back, 4=forward) через локальный `NSEvent`-монитор в `AppDelegate` (не под XCTest, token хранится для симметрии teardown); съедаются только когда key-окно документное (`representedURL != nil`), нав no-op'ит на краях.
- **Scope — только главное окно** (ревью-фикс). История пишется и таргетится исключительно главным окном: visits кладёт явный `recordVisit` из `openInMainWindow`, а `navigateToHistory` ВСЕГДА открывает в главном окне (не уводит фокус в lite-окно). Прежний `windowDidBecomeKey`-observer и фокус существующего lite-окна убраны: они ломали restore (lite-`consumePendingControlJump` гейтнут `isMain`, оффсет повисал pending) и штамповали main-каретку на lite-visit. Lite-окна теперь независимы от навигации главного окна. Без observer'а `DocumentHistory()` уже изолирован — тесты строят свой инстанс.
- **Границы восстановления позиции.** Оффсет = каретка Source/Visual. В standalone Preview `reverseScrollEnabled == false` — позиция чтения нигде не пишется, поэтому файл, прочитанный в Preview, восстановится на последнюю каретку (часто начало). Cold start = Preview → Back туда попадает под это ограничение. Same-file `[[этот#заголовок]]`: dedup по URL → нет нового visit, Back НЕ откатывает in-page прыжок к заголовку (cross-file — ок); осознанно out of scope.
- **Инвариант.** Browser-семантика (новый переход обрезает forward-хвост), relocate/discardPaths при перемещении файлов работают по `entries`. Suite `Document history Back/Forward` покрывает стек, dedup, обрезание хвоста и штамповку/восстановление оффсета.

## Тулбар: правый инспектор + единый набор кнопок (2026-07-20)

- **Кнопка инспектора.** Правый инспектор (Outline/Info/Git/Review/Tags) раньше открывался только через View ▸ Show/Hide Inspector (⌥⌘0) — теперь есть видимый тумблер `sidebar.right` на trailing-крае, как в Xcode.
- **Единый набор на всех ветках.** Trailing-кнопки (appearance / agent / inspector) вынесены в `EditorToolbar` и хостятся `MainChrome` (главное окно, ВСЕ центральные ветки: welcome/folder/pdf/image/editor), чтобы набор не менялся между «info-режимом» и открытым файлом. `ContentView` отдаёт этот набор только для lite-окон (`if !isMain`) — у них нет `MainChrome`, иначе был бы двойной тулбар. Инспектор-кнопка присутствует везде, но `.disabled` вне `isEditorBranch` — та же логика, что у пункта меню (focused-value nil на не-документе).
- **Active-состояние.** Тумблеры сайдбара и инспектора — `Toggle` + `.toggleStyle(.button)`: активное (открытое) состояние рисует сам macOS. Ручной `.foregroundStyle(accentColor)` на тулбарных SF Symbols часто игнорируется (template-режим), поэтому не он. `appearanceIsDark` вынесен в `AppearanceMode.isDark` (один источник для обоих хостов).

## Git-панель: группировка по workspace (2026-07-21)

Мотив пользователя: «мне очень тяжело разобраться, что в ней происходит». Причина — панель со времён v35 группировала по **git-репозиторию** и титульной строкой ставила имя ветки, поэтому четыре adopted-папки читались как четыре одинаковых `main`/`master`, а сама папка уходила в мелкий серый путь; каждая чистая секция при этом тратила четыре строки (Refresh / Push / CHANGED (0) / Working tree clean).

- **Секция = adopted-папка, не репозиторий.** `GitRepoSection` получила `workspace` + `name` (имя из сайдбара, включая `customName`), `id` по пути папки; вход снапшота — `GitWorkspaceInput` (url + имя). Две папки внутри одного репо дают две группы, порядок групп — порядок сайдбара. При этом git по-прежнему опрашивается **один раз на репозиторий**: branch / ahead-behind / porcelain кэшируются в `repoStates` и переиспользуются всеми его папками. Файл относится к самой глубокой adopted-папке (вложенное усыновление не дублирует строки).
- **Сворачивание с производным дефолтом.** Грязная папка открыта, чистая свёрнута в одну строку. Персистится не множество открытых, а **overrides** к дефолту (`GitSidebarDisclosureStore`), и `GitSidebarDisclosure.pruned` после каждого снапшота выбрасывает override, совпавший с дефолтом. Иначе однажды свёрнутая грязная папка осталась бы запертой на все последующие циклы «стала чистой → снова грязная». Правила — чистый `GitSidebarDisclosure` (isExpanded / toggled / pruned) с юнит-тестами.
- **Фильтр не имеет права красить грязное в чистое.** Первая версия строила усечённую копию `GitRepoSection`, и группа, выжившая по совпадению имени/ветки/пути, рисовалась с пустым списком — то есть как чистая. Рендер идёт через `GitSidebarGroup { section, files }`: счётчик, приглушение имени и `hasChanges` берутся из полной секции, а для «файлы скрыл фильтр» есть отдельная формулировка. Тот же класс ошибки в шапке-итоге: она считала только porcelain и писала «все папки чистые» при несохранённых буферах, которые тут же перечислены ниже.
- **Hover-действия без прыжков.** Refresh/Push держат фиксированные слоты 18×18 всегда, видимость — `opacity`, а `allowsHitTesting(visible)` не даёт невидимой иконке поймать клик (иначе клик по «пустому» месту делал бы push). Зоны раскрытия — **siblings** иконок, никогда не предки: перекрывающиеся tap-таргеты съедают первый клик (та же гоча, что документирована для `changedRow`). Контекстное меню группы дублирует действия для клавиатуры/VoiceOver; скрытые иконки помечены `accessibilityHidden`.
- **Семантика Commit all различается намеренно:** в футере — то, что на экране (`group.files`, «коммить, что видишь»), в контекстном меню — вся папка (`section.files`, меню висит на папке).
- **Локализация.** `editMDHelp` и `sectionHeader` принимают обычный `String`, поэтому литералы тултипов Git-панели никогда не извлекались и жили в каталоге как `stale` — переведены через `String(localized:)`; туда же ушли подсказки ahead/behind (и в `GitStatusChip`), у которых ключи существовали пустыми.
- **Гоча `Spacer` + `layoutPriority`.** Приоритет сжатия расставлялся, чтобы имя папки не схлопывалось в «…» раньше ветки, — и `layoutPriority(1)` попал на зону, внутри которой остался `Spacer`. Spacer запрашивает неограниченную ширину, поэтому с повышенным приоритетом забрал всё: соседняя зона раскладывалась в 0pt, её текст переносился **по одному символу** и раздувал строку в несколько раз по высоте. Симптом читается как «статусы пропали», хотя они разложены в нулевую ширину. Правило: гибкий зазор — отдельный sibling (`Color.clear` с `maxWidth: .infinity`), а не житель приоритетной зоны; короткие обязательные метки (`↑N`, счётчик, «чисто») — `fixedSize()` + `lineLimit(1)`.


## Source: полоса текущей строки и цвет каретки (2026-07-21)

Мотив: в Source не было признака, где стоит каретка — все номера строк рисовались `tertiaryLabelColor`, а точка ввода наследовала цвет текста и в моноширинном буфере читалась как тяжёлая чёрная плашка. Ориентир — Xcode (пользователь принёс скриншот).

- **Полоса** заливает жёсткую строку с кареткой поперёк читательского поля: накрывает номер строки (как в Xcode), начинается на `bandLeadIn` левее номеров и кончается за `bandRightMargin` от правого края. Левый край выводится из резерва гаттера: номера выровнены по правому краю на `inset.width − gap` и занимают `reserve − gap − edgePad`, поэтому `applyReadingInsets` запоминает `reserve` в `SourceNSTextView.gutterReserveWidth`. Мягко перенесённая строка подсвечивается целиком (объединение фрагментов), пустая строка после хвостового `\n` — через `extraLineFragmentRect`.
- **Номер строки с кареткой** рисуется полным `labelColor`. Изменённая строка сохраняет свой (зелёный) цвет: какие строки поменялись — сведения, которых позиция каретки не заменяет.
- **Принадлежность строки — чистый предикат**, а не `lineRange` по зажатому смещению: каретка после хвостового `\n` принадлежит пустой последней строке, а «конец строки» засчитывается только строке без завершающего перевода. Первая версия отдавала такую каретку строке выше — поймано тестом до запуска.
- **Производительность.** В `GutterState` едет **смещение**, а не номер строки: сопоставление происходит в проходе отрисовки, который и так обходит видимые жёсткие строки. Номер потребовал бы прохода по всему префиксу файла на каждое движение каретки. Перерисовка планируется только при реальной смене строки.
- **Один гейт на полосу и на номер** — `gutterEmphasisOffset`, возвращающий nil для любого ranged-выделения. В первой версии полоса гасла, а номер строки-якоря продолжал светиться, объявляя одну «текущую» строку посреди многострочного выделения.
- **Wash накладывается при отрисовке, а не в настройках.** Кастомный цвет приходит из пикера непрозрачным (`NSColor(hex:)` = alpha 1) и в первой версии закрашивал подсветку сплошной плашкой. Настройки отдают тон и непрозрачность (0 = дефолт темы 0.07/0.14), альфа считается в `drawCurrentLineHighlight` по appearance самого view — иначе смена light/dark требовала бы круга через настройки.
- **Гоча резерва.** `settingsDidChange` переприменял insets без `gutterReserve`, дефолтный 0 затирал сохранённое значение, и полоса возвращалась к левому краю до следующего `updateNSView` (видно при перетаскивании слайдера непрозрачности). Путь настроек передаёт свой резерв, а `applyReadingInsets` не перезаписывает известный резерв нулём от вызывающего, который его не знает.

## Пол ширины боковых панелей = их собственная лента табов (2026-07-21)

Мотив: правый инспектор перетаскивался до 150pt, а его пилюля навигатора требует полный бюджет табов — хвостовые табы (Links / Backlinks / Info) уезжали под край панели. У левого сайдбара тот же дефект в миниатюре: пол 150 против бюджета ленты, подрезался Tags.

- **Пол выводится из метрик ленты**, а не из числа: `SidebarChrome.navigatorPillWidth(tabs:)` + `2 × barPaddingH`. Добавится таб — пол поедет сам.
- **Лента — кастомная Xcode-капсула, не `NSSegmentedControl`.** *(Отменено в тот же день — см. следующий раздел: ручная капсула выброшена, лента = системный `NSSegmentedControl`.)* Мотив на тот момент: flex-табы на всю ширину панели, выделение-`Capsule` (круг на floor width, овал при растягивании), хайрлайны что гаснут по бокам active, точка-бейдж на Review, per-tab tooltip.
- **Диапазон и дефолт инспектора живут в одном `InspectorPane`**: редактор (`ContentView`) и карточка папки (`FolderInfoHost`) пишут один и тот же ключ `inspectorWidth`, раньше `150…400` и дефолт 220 дублировались в обоих и могли разъехаться.
- **Пол ограничивает только preferred-ширину** (drag + кламп сохранённого значения на чтении). Дисплейный сжим `resolveSidePaneWidths` его сознательно игнорирует: это последняя защита от наложения панелей. В минимальном окне (900) с сайдбаром на максимуме (400) инспектору достаётся ~238 из 264, и один таб подрезается. Альтернатива — продавить редактор ниже `editorColumnMinWidth` (наложения не будет, редактор гибкий) — отклонена: сжатое состояние и так деградировавшее. Поведение зафиксировано тестом, чтобы не выглядело сюрпризом.
- **Кламп на чтении обязателен обеим панелям**: у пользователя в `AppStorage` уже могло лежать 150, и без клампа панель открывалась бы подрезанной до первого перетаскивания.
- **Курсор ресайза на разделителе.** Жалоба «тяжело поймать ↔» была не про размер зоны, а про то, кто владеет курсором: `.onHover { NSCursor.resizeLeftRight.set() }` проигрывает гонку, потому что AppKit на каждом mouse-moved заново разрешает курсор по cursor rects вью под указателем — I-beam соседнего текстового вью тут же отыгрывает обратно, и ↔ только мигает. Решение — `.onContinuousHover`: курсор переустанавливается на каждое движение внутри полосы, поэтому чужая победа живёт максимум до следующего mouse-moved. Заодно четыре копии разделителя (сайдбар, инспектор редактора, инспектор папки, сплит Source/Preview) сведены в один `PaneDivider`, а зона захвата поднята с 12 до 14pt.
  - **Тупик, в который не надо возвращаться** (был закоммичен и откатан, f32f4b9 → 1f8ee5d): «честный» AppKit-путь — невидимая полоса с `addCursorRect` + tracking area `.cursorUpdate`. Чтобы не перехватывать мышь у SwiftUI-drag, её `hitTest` возвращал nil, а это выкидывает вью ровно из того резолва курсора, ради которого она добавлялась: ↔ пропал совсем. `hitTest` → nil и владение курсором несовместимы; либо вью принимает мышь и тогда drag тоже переезжает в AppKit, либо курсор ставится из SwiftUI.
  - **Осознанный компромисс:** если мышь замерла над полосой, сосед может перекрыть курсор до следующего движения. Для resize-таргета это приемлемо — за ним тянутся мышью, — и это не повод возвращать cursor-rect подход.
- **Гоча изоляции.** Статические метрики жили внутри `View`-структур, а conformance `View` изолирует тип в `@MainActor` — nonisolated `InspectorPane`/`sidePaneWidthRange` читать их не могут. Помечены `nonisolated static` (чистая геометрия, ничего от AppKit). Тем же заходом убраны реальные Swift 6 нарушения по соседству: `AppAppearance.isDark` спрашивает `NSApp` → `@MainActor`; `applyWindowContentMinimum` трогает `contentMinSize`/`setFrame` → `@MainActor`, а `WindowAccessor.configure` объявлен `@MainActor (NSWindow) -> Void` и вызывается через `MainActor.assumeIsolated` внутри `DispatchQueue.main.async` (очередь main и есть main actor, лишний хоп через `Task` дал бы окну смениться под руками).
- **Гоча сборки.** Правки в `EditMDTests` не попадали в прогон: `xcodebuild test` и `build-for-testing` рапортовали SUCCEEDED, не перекомпилировав тест-бандл (`EditMD.app/Contents/PlugIns/EditMDTests.xctest` оставался старым). Признак — счётчик «Executed N tests» не вырос и новых имён нет в логе; лечение — `rm -rf ~/Library/Developer/Xcode/DerivedData/EditMD-*/Build`. Зелёный прогон в такой ситуации подтверждает не тот код.

## Лента навигатора = системный NSSegmentedControl (2026-07-21)

Финал саги из пяти коммитов за один вечер (стоковый `Picker` → обёртка `NSSegmentedControl` → ручная Xcode-капсула → снова системный контрол). Пользователь: «никак не могу справиться с панелью инструментов в сайдбарах — посмотри, как делает Apple по гайдлайнам, и сделай так же».

- **Решение: перестать имитировать Xcode.** Xcode-строка навигатора — кастомный AppKit-хром самого Xcode, а не системный паттерн; её реплика на SwiftUI требовала ручных хайрлайнов, гашения соседних штрихов, circle→oval-пилюли и капсулы-подложки — и всё равно расходилась с системным рендером. По HIG место переключателя режимов панели — segmented control; его вид рисует AppKit.
- **Обёртка, не SwiftUI `Picker`:** пикер держит intrinsic-ширину (центрируется в панели, `segmentDistribution` не пробрасывается) и не умеет per-segment tooltip. `SidebarNavStrip` = `NSViewRepresentable` над `NSSegmentedControl`: `.fillEqually` растягивает сегменты с панелью, `setToolTip(forSegment:)` возвращает подсказки (Review несёт счётчик открытых меток), `sizeThatFits` отдаёт proposed width + собственную высоту контрола.
- **Бейджу нет места в сегменте** — таб Review с открытыми метками меняет символ на `text.bubble.fill` (поле `badgeSystemImage`), счётчик живёт в tooltip.
- **Полы панелей пересчитаны:** floor сегмента 28pt (читаемость 13pt-символа; `fillEqually` жмёт дальше, но иконки перестают читаться) → инспектор 7×28+16 = 212, сайдбар 4×28+16 = 128 (`PaneLayoutTests`). Метрики капсулы (`navPillPaddingH`, `navDivider*`, `navSelectionMaxWidth`) удалены; `iconButtonWidth/Height` 24 остались кастомным стрипам (folder actions, editor strip).
- **Вертикальные отступы ленты** `barPaddingTop/Bottom` 0/0 → 6/4: капсула сидела вплотную под тулбаром (так в Xcode), у системного контрола с bezel нужен стандартный воздух. Константы общие — полоса folder-info/welcome/editor strip сдвинулась вместе.
- **Не гонять NSImage на каждый апдейт:** координатор кэширует применённые имена символов и трогает `setImage` только для сегмента, чей символ реально сменился.

## Унификация всех баров на системных контролах (2026-07-21)

Продолжение сегментед-развязки: пользователь попросил «проинспектируй все тулбары и унифицируй по гайдлайнам Apple/SwiftUI». Инвентаризация: оконный NSToolbar (уже нативный), навигаторы сайдбаров (уже `NSSegmentedControl`), и четыре самодельных капсульных бара — лента редактора, нижние бары сайдбаров, action strip карточки папки, строка Welcome.

- **Deployment target 13.0 → 14.0** ради `.buttonStyle(.accessoryBar)` — системного стиля для баров над контентом (Notes/Freeform). Заодно схлопнут гейт `OptionalPulse` в AgentActivityUI.
- **`BarControls.swift`:** `AccessoryBarButton` (glyph symbol/text; `active == nil` → Button, `Bool` → Toggle, on-state рисует macOS) и `AccessoryBarMenu` (`.menuStyle(.button)` + accessoryBar). Ручные капсулы-подложки, хеирлайны-разделители и accent-tint активных кнопок удалены во всех четырёх барах.
- **Переключатель режимов** Source/Visual/Preview/Split — реюз `SidebarNavStrip` с новыми ручками `fillsWidth: false` (`segmentDistribution = .fit`, intrinsic width) и `controlSize: .regular`. `EditorMode.activeSystemImage` умер — выделение рисует сам контрол.
- **Фильтры** внизу обоих сайдбаров и поле запроса Search-таба — `FilterSearchField` (`NSSearchField`: лупа, крестик, focus ring). Крестик очистки в Search идёт через `setQueryText("")` (debounce-путь), а не старый `model.clear()` — осознанно.
- **Механика ленты редактора не тронута:** measurement layer, greedy overflow в «…», геометрия insets — всё прежнее; поменялся только хром (`pill`/`sep`/`icon`/`labelBtn` → `cluster` из accessory-кнопок).
- `wellColor` остался только у контентных подложек (чипы тегов и карточки плагинов PropertiesPanel) — это не бары.


## Визуальный язык Visual — план 11, этап 11.0: колонка и baseline-миграция (2026-07-22)

Старт спринта по `docs/plans/11-visual-typography.md` (v2 после арт-ревью пользователя): уход от GitHub-имитации (`EditorTheme.github`) к Apple/HIG-типографике. Порядок принципиален: сначала мера строки, потом калибровка ритма под неё.

- **Prose-колонка по умолчанию:** дефолт Visual `columnWidth` 0 → 736 (та же константа, что у Preview; механика reading column уже существовала). Full width возвращается через `0`; тумблер «Limit column width» в Settings теперь включает 736, а не 720.
- **Жёсткая baseline-миграция** (решение пользователя: «дизайн заново — старые значения убирай»): stamp `editorSettings.visualTypographyBaseline` в UserDefaults; при значении меньше `EditorSettings.visualTypographyBaseline` (=2) сохранённые `visual.elements` и `visual.columnWidth` перезаписываются текущими дефолтами — старые per-element кастомизации сознательно теряются. Личные `fontSize`/`insetH`/`insetV`/`fontFamily`/`fontWeight` сохраняются. Логика вынесена в чистую `EditorSettings.migratedVisual` (тесты в `EditorSettingsMigrationTests`). Этап 11.2 сменит дефолты `ElementStyles` и обязан поднять stamp до 3, иначе существующие установки не увидят новую шкалу.
- **Контрольный лист** `demo-typography.md` в корне — pass/fail всего спринта (пары ритма, кириллица/mixed, цифры/emoji/длинные URL, многострочный H1, плотный технический абзац, таблица с числами и длинной ячейкой). Фикс-условия просмотра: окно 1000×800, колонка 736, база 15, spacing 1.0, light+dark.
- didSet-персист `EditorSettings` не срабатывает в `init` — мигрированное значение и stamp пишутся явно.

## Визуальный язык Visual — план 11, этапы 11.1–11.6 (2026-07-22)

Реализация остальных этапов плана 11 (каждый — отдельный коммит; глазами на момент записи не проверено):

- **11.1 Ритм.** Leading — как CSS-ratio от кегля элемента через `minimumLineHeight` (floor), НЕ `lineHeightMultiple`: тот умножает естественную высоту строки (уже ~1.2× кегля) и даёт перебор (~1.55 в CSS-терминах). Body/списки/цитаты 1.30, листинги 1.20. Абзацы с attachment-глифами (картинки, formulas, thematic break — проверка на U+FFFC) остаются на дефолте шрифта. paragraphSpacing 6→8, элементы списка 2→3, конец списка 6→8.
- **11.2 Заголовки.** Новая шкала `ElementStyles` 1.75/1.45/1.2/1.07/1.0/1.0 (H1 bold, остальные semibold, H6 в secondary по умолчанию — draw-time, не запечённый hex). Интервалы 26/22/16/12 before (3:1 к after), заголовок сразу за заголовком половинит before (`ParaScan.isHeading`). Leading заголовков зажат с двух сторон (`min==max`, 1.12 для H1–H3, 1.18 дальше). Оптические капы приращения в `headingSize`: H1 ≤ base+16, H2 ≤ +10, H3 ≤ +6, H4+ ≤ +4 — на слайдере sizeScale выше ~2 у H1 при базе 15 виден потолок, это осознанно. Дивайдеры H1/H2 удалены целиком (`headingDividerColor`, ranges, отрисовка). Stamp миграции поднят до 3.
- **11.3 Инлайн.** Inline-код: нейтральный цвет (= textColor) на полупрозрачном wash `ghAlpha(0.055/0.09)`; в Source от смены `theme.inlineCodeColor` меняется только tint сырых math-runs — inline-код там красится темой лишь при явном element-override — это шаг A решения «pill vs плоский», pill вводится только после просмотра. Ссылки: постоянный underline убран; аффордансы — underline при каретке внутри ссылки и при ⌘-hover (temporary-атрибуты layout manager, layout не трогают; `updateCaretLinkAffordance` из selection-хука координатора, hover из `mouseMoved`/`flagsChanged`); при Increase Contrast presentation pass возвращает постоянный underline, а temporary-состояния молчат. Done-задачи: secondary без перечёркивания; strike остался у `~~del~~` и у плагинных токенов с их конфигом.
- **11.4 Блоки.** Маркеры списков — secondary, точка ≤2pt радиуса; номера — `monospacedDigitSystemFont` (0.75× базы), secondary, right-aligned; чекбоксы остались accent (интерактив). Обычные цитаты: бар 2pt secondary@0.45, wash убран (`quoteBackground = .clear`), текст secondary; callouts не тронуты. HR — hairline 1pt с воздухом 16/16. Code panel: радиус 8, рамка `separatorColor`. Единый `VisualStyle.codeSize` = `max(base×0.88, min(base, 11))` для inline-кода, листингов и их leading.
- **11.5 Таблицы.** Общие токены native/island. Итоговая сетка (после просмотра пользователем — план предлагал «только горизонтали», переиграно): полная тонкая сетка 0.5pt (вертикали и рамка как линии строк), 1pt под header, у native обязателен `NSTextTable.collapsesBorders = true` — иначе смежные ячейки рисуют каждая свою рамку и линии двоятся; утолщение header — по-рёберная ширина `setWidth(...edge: .maxY)` (при коллапсе побеждает более толстая линия). Заливка header убрана в обоих. Паддинг ячейки 8 (native padding, island pad + measure-константы 16). Табличные цифры: `blockKind == .tableCell` даёт `monospacedDigitSystemFont` (кастомная семья пользователя — без подмены), island берёт те же шрифты. Floor высоты строки ячейки = body 1.3 → покойная строка ~34–36pt.
- **11.6 Изображения.** Битое/грузящееся изображение — панель 260×60 (фон code panel, иконка `photo` + имя файла в secondary, truncating middle) вместо голого глифа; загруженные изображения клипятся под радиус 6 через лениво рисующий NSImage-враппер.

Не сделано из плана: pill-решение (шаг B 11.3 — после просмотра), тонкая подгонка чисел по глазам, проверка узкого Split и баз 12/15/20 глазами. PDF-экспорт не затронут (Preview HTML). Контрольный файл — `demo-typography.md` в корне.

**Follow-up по глазам (2026-07-22):** пользователь вернул полную сетку таблиц (детали влиты в bullet 11.5 выше); hover-only вертикали island и `hoveredIslandLocation` убраны как ненужные. По внешнему ревью пачки: rect-check против «фантомного» ⌘-hover/⌘-click по ближайшей ссылке из пустоты (`glyphIndex(for:)` снапится к ближайшему глифу), возврат I-beam после ухода hover-состояния, `refreshLinkAffordances()` в конце presentation pass (re-stamp runs / переключение Increase Contrast), выпилены мёртвые `tableRowBackground`/`listItemSpacing` из темы.

## Ревизия кнопок стрипа и план 12 (2026-07-22)

Ревизия состава кнопок (утверждена пользователем): Inline получил кнопку Link (⌘K существовал без кнопки), группа Insert (Image/Divider/Code Block/Table/Formula) видна в обоих редакторских режимах — Source вставляет markdown-шаблоны через `blockSnippet` (fence-guard как у paste), тройка «T/Aa/aA» свёрнута в меню-ластик Cleanup, H1–H3 — отдельная группа Headings. Row/column ops таблиц — Visual-only (`showTableOps`).

**Происхождение общего колодца стрипа** (фиксация задним числом — ревью плана 12 споткнулось об отсутствие записи): спринт унификации оставил `wellColor` только контентным подложкам, но ПОЗЖЕ пользователь по глазам выбрал общий well `quaternarySystemFill` за всеми тулами стрипа («user-picked look» в комментарии `EditorActionStrip`) — он зеркалит bezel сегментного переключателя, чтобы тулы и switcher читались как родственные панели. Это осознанное исключение из «бары без подложек», не регрессия.

План 12 (`docs/plans/12-strip-grouping.md`, v3 после двух агентских ревью): 12.0 — правая граница ленты всегда mode-switch (была — trailing-margin колонки текста в не-split, отсюда «…» при пустом баре); 12.1 — границы групп интервалом `groupGap` 12pt (hairline отклонён дважды), к «…»/switch — 8pt; 12.2 — двухступенчатый overflow (группа сжимается в кнопку-сабменю со стрелкой: insert → lists → headings, затем общий «…»), testable-планировщик `StripLayoutItem` и дерево команд `StripCommandNode` с flatten-инвариантом «ширина окна не меняет набор действий».
