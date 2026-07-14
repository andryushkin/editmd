# EditMD — Claude Guide

## Overview

Минималистичный Markdown редактор для macOS. Чистый SwiftUI App lifecycle. **С v28 — `WindowGroup` + собственный `DocumentRegistry`** (уход от `DocumentGroup`): главное окно с файловым сайдбаром меняет файл на месте, отдельные lite-окна — value-based `WindowGroup(for: URL)`; `MarkdownDocument` = модель контента, сериализация/IO в `DocumentStore.swift`. NSTextView обёрнут в `NSViewRepresentable` для подсветки синтаксиса. **Три режима** (переключатель в ленте над текстом + ⌘1/⌘2/⌘3 в View-меню, курсор/скролл сохраняются между режимами):

- **Source** — сырой markdown, моноширинный; подсветка синтаксиса по настройкам (per-mode элементы: заголовки/жирное/код/цитаты/ссылки — размер/вес/цвет через `collectSpans`, v27) + линтер (14 правил, quick-fix) — `SourceTextView.swift`
- **Visual** — WYSIWYG на attributed-модели: маркеров в тексте нет, семантика в кастомных атрибутах, пропорциональный шрифт, таблицы NSTextTable, картинки, синхронная сериализация в markdown — `VisualTextView.swift`
- **Preview** — read-only рендер в WKWebView (свой HTML-визитор + GitHub-подобный CSS; формулы `$…$`/`$$…$$` — KaTeX офлайн) — `MarkdownPreviewView.swift`

Кнопка 🎨 в тулбаре переключает тему (System/GitHub/Sepia/Nord/Solarized/High Contrast/Dracula; «comfortable» — retired-пресет, резолвится в System). File ▸ Export as PDF… (⌘⇧E) рендерит фокусный буфер через Preview-HTML офскрин (`PDFExporter.swift`). Кнопка ☀/🌙 управляет `.preferredColorScheme`. Меню — через SwiftUI `.commands` + `@FocusedValue` в `EditMDApp.swift` (File-меню теперь ручное — DocumentGroup его больше не даёт). **Интеграция с Claude Code** (v36, Settings ▸ General, default on) — локальный WebSocket/MCP-сервер на `127.0.0.1`: `claude` в терминале делает `/ide`, видит файл/выделение/workspace, правки приходят как diff с Accept/Reject (`Integration/`). **Метки-треды smotr** (v37) — sidecar `<file>.md.review.json`, вкладка Review в сайдбаре, подсветка якорей в Source/Visual, suggest Accept/Reject, очередь ➤ → `.smotr-queue.json` (+ opt-in спавн `claude -p "/smotr -pr"`). **Файловый сайдбар** (⌃⌘S, кастомный HStack-сплит + divider) — вкладки **Files/Outline/Git/Review/Tags**: Files = несколько workspace-папок (скрытые файлы, пины, rename, Copy Path) + «Открытые файлы», клик = замена файла в окне; Outline = заголовки документа; Git = workspace-scoped status + Commit/Push/Diff; Review = метки-треды; Tags = frontmatter-теги workspace (off-main скан) (`WorkspaceSidebar.swift` + `GitSidebar.swift` + `OutlineSidebar.swift` + `ReviewSidebar.swift` + `TagsSidebar.swift`, `WorkspaceModel.swift`). При запуске всегда открыта Files. **Сплит редактор+превью** (⌥⌘P) — Source/Visual слева + живой Preview справа. **Лента инструментов над текстом** (`EditorActionStrip.swift`) несёт форматирование слева (по левому краю колонки), переключатель режимов справа (по правому краю колонки) и тумблер номеров строк «123» над колонкой цифр; не влезшие группы уходят в меню «…». Window-тулбар (`EditorToolbar.swift`) — плоские иконочные кнопки в стиле agterm: сайдбар, Cut/Copy/Paste, сплит, тема, ☀/🌙. **Settings-окно** (⌘,) — вкладки General/Source/Visual/Preview: шрифт/отступы/ширина колонки по каждому режиму отдельно, тема + цвета в General — `EditorSettings.swift` + `SettingsView.swift`.

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
- **v36** — интеграция с Claude Code, фаза 1: локальный WS/MCP-сервер (`/ide`), 12 IDE-tools, `openDiff` с Accept/Reject (app 0.36.0)
- **v37** — метки-треды smotr-style: sidecar + вкладка Review + подсветка якорей + очередь/агент (app 0.37.0)
- **v38** — `editmdctl` + unix-socket control channel + skill installer (app 0.38.0)
- **todo-спринт после v38** (версия не поднималась) — пачка из `docs/todo.md` по плану `docs/plan-sonnet-todo.md`: сайдбар-мелочи (Copy Path, rename workspace, вкладка Files по умолчанию, подсветка активного корня), `EditorToolbar.swift` (вынос из ContentView), кнопки/активные состояния format-strip во всех трёх режимах (в Preview — через DOM), lint-чип со списком в статус-баре, экспорт в PDF (`PDFExporter.swift`), вкладка Tags (frontmatter-теги), `workspace.add` в control-канале, темы Sepia/Nord/Solarized/High Contrast/Dracula, демо `KitchenSink.md`, sync скролла в сплите, markdown-вставка в Visual + фиксы по код-ревью спринта
- **таблицы-спринт после v38.1** (версия не поднималась) — структурные операции таблиц: строки/столбцы относительно курсора через контекстное меню в Visual (нативные + island) и Source, drag-перенос строк за ручку в Visual, вставка таблиц из буфера (HTML web/Word/Excel + TSV → pipe-таблица, `TableClipboard.swift`), `renderForInsertion` (remap групп при вставке рендера), тулбарные «Добавить/Удалить строку» стали курсор-зависимыми
- **pdf-спринт** (версия не поднималась) — просмотр PDF: PDFKit-вьювер (`PDFViewerView.swift` — `PDFViewerHost` в главном окне с сайдбаром и в lite-окнах, мимо `DocumentRegistry`), PDF в листингах сайдбара/карточки папки/tree-stats (папка только с PDF ≠ «пустая»), wiki-links резолвят PDF (bare `[[Name]]` предпочитает .md, явное `.pdf`/`.md` в таргете фильтрует по типу), File ▸ Open принимает PDF. Плюс **локальные markdown-ссылки как в Obsidian** (`[pdf](/research_pdf/x.pdf)`): `openMarkdownLink`/`resolveLocalLinkDestination` (WikiLinkResolver.swift) — ведущий `/` = от корня vault (adopted workspace, fallback — ближайший предок с `.obsidian`), иначе от папки файла; `#fragment` и percent-encoding срезаются; md/pdf открываются в EditMD, прочее — системой. Поверхности: Preview — JS-хендлер `localLinkClick` (schemeless href не резолвится против about:blank-базы loadHTMLString, потому JS, не decidePolicyFor), Visual — ⌘-клик больше не требует scheme у `.mdLink`
- **формулы-спринт (v39)** — LaTeX-формулы `$…$`/`$$…$$` через все три режима: `MathScan.swift` (сканер + маска U+E000, код пропускается, валютные гарды), Preview = KaTeX-рендер офлайн (`Resources/katex/` — js + css с data-URI-шрифтами, вшивается в страницу только при наличии формул; `KaTeXResources.swift`), Source и Visual тоже парсят маскированный текст (`=`-строка в `$$` не делает setext-H1); Source = `.mathBody`/`.mathMarker` в `collectSpans`, Visual = РЕНДЕР формул SwiftMath-аттачментами (`MathAttachment.swift`, вербатим в `.mdMathTex`; двойной клик → попап-редактор `MathEditorPopover.swift`, ⌘⏎ применяет; неразобранный TeX — тонированный сырой текст с `.mdMath`), кнопка ∫ в strip = вставка формулы + сразу редактор. `markdownHTMLRender` возвращает `(body, hasMath)`; demo-formulas.md в корне

- **подсветка-кода-спринт (0.39.1)** — highlight.js через JavaScriptCore (SPM `HighlighterSwift`) во всех трёх режимах: `CodeSyntaxHighlighter.swift` — один источник токенов для Source/Visual (цвета в storage) и Preview/PDF (HTML-спаны); языки нормализует `CodeLanguageRegistry` (алиасы `sh`→`bash` и т.п.), неразмеченные блоки НЕ автодетектятся. Настройка General ▸ Syntax highlighting (default on). Frontmatter-YAML тоже идёт через этот путь (Source + Visual-остров + Preview), Obsidian-панель свойств в Preview — `frontmatterPropertiesHTML`

- **формулы-фиксы (0.39.2)** — цвет формул в Visual резолвится НА ОТРИСОВКЕ (`MathAttachment.tinted`: силуэт + `NSImage(size:flipped:drawingHandler:)`, `cacheMode = .never`) — снимок `NSApp.effectiveAppearance` запекал белые глифы в светлое окно; display-формулы в Preview получили собственный вертикальный ритм (`.math-display { margin: 1.1em 0 }`, внутренний `.katex-display` обнулён — `overflow-x` делает блок BFC, его margin не схлопывается, а складывается)

- **гаттер-и-strip-спринт (0.39.3)** — переключатель режимов уехал из window-тулбара в `EditorActionStrip` (закреплён у правого края колонки; не влезшие группы инструментов уходят в меню «…» — `StripItem` = один источник для pill и пункта меню, ширины меряет скрытый measurement-слой). Номера строк ушли из `NSRulerView` (AppKit прибивает его к краю панели — далеко от центрированной колонки): Source/Visual рисуют их в левом инсете текста (`LineNumberGutter.swift` — `GutterMetrics`/`GutterState` + `NSTextView.drawGutterNumbers`), в 18pt от текста, как рельс Preview; инсет резервирует это поле всегда. Кнопка «123» (тумблер номеров) — в ленте над колонкой цифр; позиции ленты и кнопки считает общий `EditorFieldGeometry.swift`. Preview: номера у код-блоков не рисовались (`pre { overflow-x: auto }` клипал `::before`) — прокрутка переехала на `pre code`

**Осталось на будущее:** remote-картинки в Visual (async загрузка), undo через границы переключения режимов, drag&drop картинок, per-document запоминание режима (идея FSNotes, отложена), поиск внутри Preview (WKWebView.find / кастомная панель как MPreviewFindPanel в FSNotes), **перенос широких ячеек в Visual-grid** (v32 в Source перенос невозможен — plain text; wrap уместен в нарисованной сетке v31: многострочная ячейка + рост высоты строки). Wiki-links Фаза-5 хвосты: стиль несуществующих ссылок, heading/block-скролл, `[[`-автокомплит.

**Принятые решения:** Visual — пропорциональный шрифт, Source — моноширинный. Source of truth — markdown-строка в MarkdownDocument; Visual сериализует при смене режима/сейве/дебаунсе. Undo-стек сбрасывается при смене режима. Гибрид v17 остаётся Visual-режимом до v20. **Ревью-метки (v37 smotr): primary surface = Preview** — выделять текст, ставить метки, видеть wash якорей и jump к карточке; Source/Visual вспомогательны (правка source of truth, WYSIWYG-правка, те же якоря в temporary-attrs).


## Ключевые инварианты (сводка; детали и контекст — в `docs/HISTORY.md`)

- **Round-trip держит `.raw`** — display-текст островов (большие таблицы, frontmatter) косметичен и может отличаться от исходника; сериализатор читает `.raw`-атрибут дословно (v31/v33).
- **Не класть тяжёлые значения в атрибуты NSAttributedString без дешёвого `hash(into:)`** — NSTextStorage хеширует значения атрибутов при `fixAttributes`; `String.count` = O(n), в hot-path не вызывать (v29).
- **Два независимых порога**: `maxNativeTableCells` (island vs `NSTextTable` в Visual, по ячейкам) и `markdownIsHeavy` (plain vs подсветка в Source, по размеру+таблицам) — не путать (v29).
- **NSTextTable: один shared инстанс на таблицу**; NSTextTable вообще не работает при `isRichText=false` (v22).
- **Source-подсветка — только реальные storage-атрибуты, не temporary** — temporary-атрибуты не влияют на layout/размер шрифта (v27).
- **`textView.string = …` / `setAttributedString` синхронно дёргают `textViewDidChangeSelection`** — читать сохранённую позицию ДО установки текста (v22).
- **Виртуализация больших таблиц = арифметика по фиксированной высоте строки** (`y = top + row*rowH`), НЕ `enumerateLineFragments` по всему острову; `.byClipping` на параграфе обязателен (v31).
- **Выравнивание таблиц в Source — display-only `.kern`**, не вставка пробелов; чистить `.kern` из `typingAttributes` (v32).
- **Три режима — три независимых парс-пути**: Source=`collectSpans`, Visual=`VisualRenderer`, Preview=`HTMLBodyVisitor` — сквозную фичу (frontmatter, wiki-links, формулы) проводить через все три (v33).
- **Плагины EditMD — только встроенные Swift-типы из `BuiltInPluginRegistry`**, с активацией на документ через frontmatter. Не добавлять загрузку JavaScript, внешних bundle или скачанного executable code; semantic token обязан сохранять UTF-16 offsets и пройти Source/Visual/Preview + round-trip.
- **Формулы: ВСЕ ТРИ режима парсят МАСКИРОВАННЫЙ текст** — math-спаны заменяются U+E000 юнит-в-юнит до cmark (`MathScan.swift`), UTF-16-раскладка и переводы строк сохраняются → все оффсеты валидны в оригинале; `LineIndex` строить от маскированного текста, не оригинала. Visual: формулы = SwiftMath-аттачменты, сериализация читает вербатим из `.mdMathTex` (fallback-раны `.mdMath` — без `escapeInline`, U+2028→`\n`); правки формул — ТОЛЬКО через попап (`replaceFormula`, undoable), голый U+FFFC без payload в файл не попадает (формулы-спринт).
- **Подсветка кода: ОБЕ палитры сразу, appearance решается на отрисовке** — `CodeTokenRun` несёт light+dark; Source/Visual кладут в storage dynamic `NSColor` (следует appearance окна → ☀/🌙-override и системная смена темы работают без rehighlight), Preview/PDF эмитят `--tl`/`--td` в спане, а `prefers-color-scheme` выбирает. Снимок «сейчас темно?» (`NSApp.effectiveAppearance`) запекал светлую палитру на тёмной странице — так не делать (подсветка-кода-спринт).
- **Highlight.js НЕ бегает на кейстроке** — прогон дорогой (замер: ~4 мс на 256 симв, ~18 мс на 1 КБ, ~58 мс на 4 КБ, ×2 палитры). Редакторы зовут `apply(…, stableKey:)` без блокировки: кэш-хит красит, промах уходит в фон (`.codeHighlightingDidWarm` → перекраска), а пока блок warm'ится — рисуются его прошлые раны (stale-while-revalidate, иначе печать внутри блока мигает серым). `blocking: true` — только для разовых рендеров (HTML, `makeSourceHighlightedString`) (подсветка-кода-спринт).
- **Номера строк рисуются в ЛЕВОМ ИНСЕТЕ текста, не в `NSRulerView`** — AppKit прибивает ruler к краю скролл-вью, и с центрированной колонкой номера оказывались за целое поле от текста. Source/Visual зовут `drawGutterNumbers` из `drawBackground`; инсет РЕЗЕРВИРУЕТ поле под цифры всегда (`GutterMetrics.reserve`), поэтому вкл/выкл номеров не двигает текст. В Visual номер рисуется только у начала блока (как рельс Preview) — дозаполнение пропущенных строк в промежутках превращало плотные места в кашу (0.39.3).
- **Лента и гаттер меряют одно и то же поле** — `EditorFieldGeometry` (левый край текста, правый край колонки, край цифр). Source/Visual репортят свой фактический инсет наверх (`onTextLeading`, async — иначе запись SwiftUI-состояния из `updateNSView`), Preview считает своё поле из `PreviewGutterMetrics` (те же числа, что в CSS). Дублировать эти формулы по месту — гарантированный рассинхрон (0.39.3).
- **Формулы/картинки в тексте: цвет решается НА ОТРИСОВКЕ** — SwiftMath запекает `textColor` в битмап, а `NSApp.effectiveAppearance` не знает про ☀/🌙-override окна. Рендерить силуэт один раз и тонировать в `NSImage(size:flipped:drawingHandler:)` + `cacheMode = .never` (тот же принцип, что парные палитры подсветки кода) (0.39.2).
- **Restamp-паттерн** для смены блок-атрибутов (`shouldChangeText` → addAttribute → `didChangeText`, undo работает) + флаг `isMutating` против рекурсии `textDidChange` (v21).
- **Свой flush файла обновляет `knownModDate` + re-arm watch** — иначе своя запись принимается за external change (v34).
- **WKNavigationDelegate в macOS 26 SDK** — только async-вариант `decidePolicyFor` (closure-вариант «nearly matches» и молча не вызывается) (v24).
- **Диагностика зависаний — `sample <pid> 3`**, не догадки: изолированный юнит-замер может не воспроизвести проблему, живой процесс покажет точный стек (v29).
- **Сайдбар не ходит на диск синхронно из SwiftUI body** — листинги папок и tree-stats идут через кэш + фоновый скан (stale-while-revalidate, `WorkspaceModel.markdownFiles`/`treeStats`); один блокирующий `contentsOfDirectory` (TCC-арбитраж, мёртвый маунт, огромный каталог) вешал всё приложение на минуты, включая тест-хост (v35.3).
- **Git Process и полный line-diff не бегут на main в per-keystroke путях** — `LineChangeTracker.noteContent` диффит большие буферы с debounce вне main actor; в SwiftUI body не должно быть computed-свойств, спавнящих git (`GitCommitSheet.branch` спавнил Process на каждый ререндер) (v35.3).
- **Правки Claude попадают в документ ТОЛЬКО через `DocumentRegistry.applyAgentEdit`** (Accept в `openDiff`) — прямая запись из tool-хендлера вернулась бы conflict-чипом как external change (v34+v36). Цена: для открытого файла undo-стек чистится.
- **`openDiff` — единственный blocking tool**: его `CheckedContinuation` обязан резолвиться ровно один раз. Accept / Reject / Esc / `close_tab` / disconnect / таймаут — все через `DiffApprovalController.resolve` (v36).
- **Интеграционный слой не поднимается под XCTest** — тест-хост писал бы реальный lock-файл в `~/.claude/ide` разработчика (`AppDelegate.isRunningUnitTests`) (v36).
- **Sidecar меток — формат smotr as-is** (`*.review.json`, `rev` + merge by id, якоря `quote+prefix`); unknown-поля в `extra`-бэге, round-trip без потерь. Схему не расширять без согласования (v37). **Якорные offsets — UTF-16 code units** (= JS-индексы smotr), поиск `prefix+quote` — NSString `.literal`; Character-арифметика сдвигала якорь на grapheme-склейке (v38.1).
- **Persist сайдкара — строго FIFO** (`ReviewModel.enqueue`: saves+reloads в одной цепочке, снапшот в момент исполнения, adoption только при `doc == snapshot`) — fire-and-forget сейвы теряли/воскрешали метки; merge в `save` не выражает удаления при гонке с внешним писателем (tombstones нет — схема smotr) (v38.1).
- **`setActiveFile` при смене файла синхронно сбрасывает doc** — мутация до приземления async-reload иначе записала бы метки предыдущего файла в чужой sidecar (v38.1).
- **Кэш якорей — `ReviewModel.anchors`** (один off-main проход, debounce 300ms за печатью): Source/Preview/сайдбар читают словарь; никаких O(текст×метки)-поисков и `@Published`-строк на кейстрок (v38.1, развитие v35.3).
- **Подсветка якорей — temporary layout-manager attrs** (фон), не storage: документ/undo чисты; lint владеет underline/toolTip, review — только `backgroundColor`, чтобы не затирать друг друга (v37).
- **Очередь/агент — диск и Process вне main** — `ReviewQueue.writeQueue` + `ReviewAgentRunner` в `Task.detached`; auto-spawn opt-in (`claudeReviewAutoSpawn`, default off) (v37).
- **Accept suggest = тот же путь, что openDiff Accept** — `DocumentRegistry.applyAgentEdit` (v34-safe); якорь пропал → `needs-rebase`, не «примерно туда» (v37).
- **Control socket всегда on (кроме XCTest)** — `~/Library/Application Support/EditMD/control.sock` (0600); override `EDITMD_CONTROL_SOCK`. Клиенты — конкурентная очередь + `SO_NOSIGPIPE` + `SO_RCVTIMEO` (один висящий клиент не голодает канал; отвал клиента не убивает app). Router — двухфазный `ControlRouter.process`: main-фаза (состояние) + deferred disk work на сокет-потоке — диск/`lineDiff` не на main; `marks.add`/`marks.list` отвечают после durable-записи (flushPipeline). Пути — только абсолютные (editmdctl абсолютизирует от cwd вызывающего); jump — `AppState.pendingControlJump` + consume при mount, не таймеры (v38/v38.1). `workspace.add` (todo-спринт) валидирует папку в deferred и мутирует `WorkspaceModel.shared` вторым socket→main хопом — тот же примитив, что main-фаза `process`; main не должен блокироваться на control-очереди.
- **Ревью-метки: primary = Preview** (wash + selection + jump); Source/Visual вторичны (v37.1).
- **Вставка рендеренного markdown в Visual — только `renderForInsertion`** (сдвиг group id за существующие) — прямой `renderMarkdownToAttributed` нумерует группы с 1, коллизия склеивает соседние same-group таблицы/списки при сериализации; структурные операции над нативными таблицами — rebuild целиком через `TableGrid` (`VisualCoordinatorTable.swift`), island-мутации — через `replaceTableIsland` (таблицы-спринт).

## Project Structure

```
editmd/
└── EditMD/
    ├── project.yml   # xcodegen конфиг — ЕДИНСТВЕННЫЙ источник структуры проекта
    ├── EditMD.xcodeproj/
    └── EditMD/
        ├── App/        EditMDApp.swift (entry point: Window("main")+WindowGroup(for:URL), ручное File-меню, commands), AppState.swift (currentURL главного окна + роутинг открытия), AppDelegate.swift (Finder open→AppState), Info.plist
        ├── Document/   MarkdownDocument.swift (модель контента, всё ещё ReferenceFileDocument — но сцену больше не питает), DocumentStore.swift (общий core сериализации .md/.textbundle + DocumentRegistry: одна модель на URL, refcount, autosave, applyAgentEdit)
        ├── Integration/ Claude Code IDE (v36) + control (v38): MCPProtocol, ClaudeIDEServer/Tools/Bridge/Service, IDELockFile, DiffApprovalController; ControlProtocol/Router/Server/Service (unix socket JSON-lines), SkillInstaller
        ├── Editor/     SourceTextView.swift (Source: подсветка + линт + review-wash + контекстное меню таблиц; `makeSourceHighlightedString` shared), VisualTextView.swift (Visual: ядро — wrapper + Coordinator: delegate, таблицы, Enter/Tab, sync) + VisualCoordinatorFormat.swift (format-действия) + VisualCoordinatorPresentation.swift (presentation-проход: шрифты/цвета/декорации из md.*-атрибутов) + VisualCoordinatorTable.swift (структурные операции таблиц: rebuild через TableGrid, renderForInsertion) + VisualNSTextView.swift (drawn markers + table-island cell editor + контекстное меню таблиц + drag строк), TableClipboard.swift (HTML/TSV из буфера → pipe-таблица), ReviewMarks.swift (smotr sidecar model + IO + anchors), ReviewHighlight.swift (temporary wash), ReviewQueue.swift (`.smotr-queue.json` + agent runner), MarkdownHighlighter.swift, CodeSyntaxHighlighter.swift (highlight.js: токены с парой палитр, off-main warm + stale-раны; HTML-спаны для Preview/PDF), MathScan.swift (сканер $…$/$$…$$ + маска), KaTeXResources.swift (бандл-ассеты KaTeX), MathAttachment.swift (SwiftMath-рендер + .mdMathTex), MathEditorPopover.swift (попап-редактор формул), MarkdownOutline.swift, FormattingHelpers.swift, EditorTheme.swift, MarkdownHTML.swift, MarkdownLint.swift, MarkdownToAttributed.swift + AttributedToMarkdown.swift, Frontmatter.swift, MarkdownTableGrid.swift, WikiLink.swift, TextDiff.swift, LineChangeTracker.swift, LineNumberGutter.swift (GutterMetrics/GutterState + рисование номеров в инсете текста), GitCommitWatcher.swift (`GitCLI` + detect-commit)
        └── Views/      ContentView.swift (layout + external-change chip + git info chip + Claude chip + lint-чип с popover), EditorToolbar.swift (window-тулбар, вынесен из ContentView), EditorActionStrip.swift (лента: инструменты + overflow-меню «…» + режимы + тумблер номеров), EditorFieldGeometry.swift (общая геометрия поля: левый/правый край текста, край колонки цифр), FileEditor.swift (DocHost + MainWindowView), FolderInfo.swift (карточка папки + tree stats), ClaudeIDEUI.swift (diff-sheet Accept/Reject + чип подключения), ExternalChangeUI.swift, GitUI.swift (Commit sheet + Push confirm + status chip + workspace git snapshot), GitSidebar.swift (Git navigator tab), ReviewModel.swift + ReviewSidebar.swift (метки-треды + ➤ очередь), TagsSidebar.swift (frontmatter-теги + off-main скан), WorkspaceModel.swift, WorkspaceSidebar.swift, OutlineSidebar.swift, EditorSettings.swift, SettingsView.swift, FocusedValues.swift (FormatActions, DocumentActions, ActiveInlineFormats), EditorMode.swift, EditorPositionStore.swift (markdownOffset = каретка между режимами; previewScrollOffset = транспорт сплит-синка, НЕ каретка), MarkdownPreviewView.swift, PDFViewerView.swift (isPDFFile + PDFKitView + PDFViewerHost), DocumentHistory.swift, WelcomeView.swift; Editor/ дополнительно: PDFExporter.swift (офскрин WKWebView → PDF); Resources/KitchenSink.md (Help ▸ Демо-разметка), Resources/katex/ (katex.js + katex.css с data-URI-шрифтами; xcodegen кладёт их в КОРЕНЬ бандла)
    EditMDTests/
        ├── MarkdownHighlighterTests.swift   # 53 XCTest кейса для LineIndex + collectSpans (все markdown-элементы)
        ├── FormattingHelpersTests.swift     # 14 XCTest кейсов для wordAndCharCount + applyWrap
        ├── EditMenuTests.swift             # 7 XCTest кейсов для MarkdownDocument
        ├── MarkdownHTMLTests.swift         # 12 XCTest кейсов для markdownHTMLBody/previewHTMLPage (эскейпинг, task list, таблицы, image resolver)
        ├── MarkdownLintTests.swift         # 30 XCTest кейсов для lint() — все 14 правил + анти-FP гарды + применение fix'ов
        ├── MarkdownOutlineTests.swift      # 9 XCTest кейсов для markdownOutline (уровни, plainText, UTF-16 оффсеты, fence/setext/blockquote)
        ├── RoundTripTests.swift            # 55 XCTest кейсов render/serialize: stable-фикстуры, идемпотентность, HTML-отпечаток, корпус
        ├── DocumentStoreTests.swift        # 7 кейсов: round-trip .md/.textbundle + assets, DocumentRegistry (shared-model/refcount, save-on-dirty, flush-on-release)
        ├── WorkspaceModelTests.swift       # 16 кейсов: скан-фильтрация (+PDF), hide/unhide, персист скрытых по пути, пины, noteOpened, frontmatter-теги
        ├── WikiLinkResolverTests.swift     # 9 кейсов: резолв по basename (рекурсивно, case-insensitive), PDF-таргеты и явные расширения, textbundle не раскрывается
        ├── FrontmatterTests.swift          # 22 кейса: frontmatterRange (детект/фенсы/малформ), parseFrontmatterProperties (scalar/flow/block-list/comment/colon-в-значении), yamlLineSegments (лосслесс/классификация), HTML-таблица + yaml-спаны, Visual round-trip
        ├── MCPProtocolTests.swift          # 15 кейсов: JSON-RPC кодек (типы id, notification, ошибки, MCP-обёртка content[0].text)
        ├── IDELockFileTests.swift          # 13 кейсов: схема lock-файла, права 0600/0700, authToken, stale-cleanup по pid
        ├── ClaudeIDEServerTests.swift      # 8 кейсов: НАСТОЯЩИЙ WS-клиент — upgrade с токеном / отказ без него, счётчик клиентов, notification без ответа
        ├── ClaudeIDEToolsTests.swift       # 40 кейсов: 12 tools против фейкового редактора + позиционная арифметика + reveal-диапазоны
        ├── DiffApprovalControllerTests.swift  # 12 кейсов: continuation ровно один раз (accept/reject/close/disconnect/timeout/повторный openDiff), Accept через реестр
        ├── ReviewMarksTests.swift          # 31 кейс: smotr fidelity, якоря, rev-guard, suggest, queue, round-trip фикстур
        ├── ControlChannelTests.swift       # 10 кейсов: codec, skill installer, socket ping/unknown
        ├── TableEditingTests.swift         # 34 кейса: grid-операции строк/столбцов, sourceTableContext, HTML/TSV из буфера
        └── MathScanTests.swift             # 25 кейсов: сканер формул (гарды валюты/эскейпов, пропуск кода), маска, collectSpans без setext-H1, SwiftMath-аттачменты
    editmdctl/                  # CLI target (v38): JSON-lines client for control.sock
    scripts/ide-smoke/ide_smoke.py  # интеграционный smoke: имитирует /ide
docs/HISTORY.md  # история версий v1–v38
docs/research/claude-code-integration.md  # спека фаз 1–3
docs/plan-claude-code-integration.md  # операционный план
visual-audit.md
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

`EditMDApp.swift` объявляет две сцены: `Window("EditMD", id:"main")` (главное workspace-окно, слушает `AppState.currentURL`) и `WindowGroup(for: URL.self)` (отдельные lite-окна). `AppDelegate.application(_:open:)` роутит Finder-открытия через `AppState` по настройке `general.liteMode` (**default true** с todo-спринта: двойной клик в Finder = lite-окно). Документы резолвятся через `DocumentRegistry` (одна модель на URL, refcount) — `DocHost` в `FileEditor.swift` делает acquire/release по идентичности вью. File-меню (New/Open/Open Folder/Save/Save As) собрано вручную; сохранение/автосейв — через реестр.

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

- `SwiftMath` (mgriebling) v1.7.3 — нативный LaTeX-типограф (порт iosMath): рендер формул в Visual (`MathImage` → NSImage + LayoutInfo для базовой линии)
- `HighlighterSwift` (smittytone) v3.1.0 — highlight.js в JavaScriptCore: подсветка код-блоков (продукт `Highlighter`; темы atom-one-light / atom-one-dark, обе гоняются на каждый блок — см. инвариант о парных палитрах)
- `swift-markdown` (Apple) v0.7.3 — официальная Swift-обёртка cmark-gfm, используется в `MarkdownHighlighter.swift` через `MarkupWalker`
    - Продукт: `Markdown` (GFM extensions включены автоматически: table, strikethrough, tasklist)
    - `swift-cmark` подтягивается как транзитивная зависимость — импортировать напрямую не нужно

> `swift-markdown-ui` удалён в v12 — Preview режим убран из приложения. `swift-cmark` (прямая зависимость) удалена в v13 — заменена на `swift-markdown` MarkupWalker.

## Conventions
