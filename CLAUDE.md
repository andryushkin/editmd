# EditMD — рабочий гайд

Короткая памятка для разработки. История решений и подробные gotchas находятся в `docs/HISTORY.md`; перед изменением конкретной подсистемы читай её раздел там. Не возвращай сюда хронологию релизов и одноразовые детали расследований.

## Что это

Нативный Markdown-редактор для macOS на SwiftUI + AppKit/TextKit 1. Главное окно меняет файл внутри workspace, lite-окна открываются через `WindowGroup(for: URL)`. `DocumentRegistry` владеет моделями, autosave и внешними изменениями; source of truth — markdown-строка в `MarkdownDocument`.

Три режима:

- **Source** — сырой markdown, подсветка и lint: `SourceTextView.swift`, `MarkdownHighlighter.swift`, `MarkdownLint.swift`.
- **Visual** — attributed WYSIWYG с синхронной сериализацией: `MarkdownToAttributed.swift`, `AttributedToMarkdown.swift`, `Visual*.swift`.
- **Preview** — в основном read-only HTML в WKWebView; интерактивны task/status-токены: `MarkdownHTML.swift`, `MarkdownPreviewView.swift`.

Сайдбар: Files / Outline / Git / Review / Tags. Сплит Source/Visual + live Preview включается ⌥⌘P. PDF и локальные изображения открываются read-only; изображения можно добавить кнопкой или вставить из буфера.

## Карта проекта

- `EditMD/EditMD/App/` — lifecycle, окна, File/Format/View commands, роутинг открытия.
- `EditMD/EditMD/Document/` — `MarkdownDocument`, `DocumentStore`, `DocumentRegistry`.
- `EditMD/EditMD/Editor/` — Source/Visual, round-trip, таблицы, формулы, подсветка, lint, review, diff, PDF export.
- `EditMD/EditMD/Views/` — layout, Preview, сайдбары, настройки, PDF/image viewer (`PDFViewerView.swift`).
- `EditMD/EditMD/Integration/` — Claude IDE WebSocket/MCP, diff approval, control socket, skill installer.
- `EditMD/EditMDTests/` — unit/integration tests.
- `EditMD/project.yml` — единственный источник структуры Xcode-проекта; после изменения состава targets/resources запускай xcodegen.
- `docs/HISTORY.md` — история фич, расследований и локальных gotchas.

Зависимости: `swift-markdown`, `SwiftMath`, `HighlighterSwift`. KaTeX лежит офлайн в `Resources/katex/`.

## Сборка и тесты

Из корня репозитория:

```bash
xcodegen generate --spec EditMD/project.yml
xcodebuild -project EditMD/EditMD.xcodeproj -scheme EditMD -destination 'platform=macOS' build
xcodebuild -project EditMD/EditMD.xcodeproj -scheme EditMD -destination 'platform=macOS' test
```

Схема уже отключает code coverage. Реальные ошибки проверяй через `xcodebuild`, а не по diagnostics одного открытого Swift-файла. После правок запускай целевые тесты, затем полный suite и `git diff --check`.

## Главные инварианты

### Документ и окна

- Одна модель на URL живёт в `DocumentRegistry`; открытые редакторы acquire/release её по идентичности.
- Правки агента и review suggestions применяются только через `DocumentRegistry.applyAgentEdit`, иначе file watcher примет их за внешнее изменение.
- Собственный flush обновляет `knownModDate` и re-arm watch.
- `ReferenceFileDocument` callbacks nonisolated; `FileWrapper` не `Sendable`, поэтому snapshot остаётся `@unchecked Sendable`.
- Стандартные Cut/Copy/Paste/Undo идут через responder chain; действия конкретного редактора — через focused values.

### Source / Visual / Preview

- Сквозная markdown-фича имеет три независимых пути: Source=`collectSpans`, Visual=`VisualRenderer`, Preview=`HTMLBodyVisitor`. Проверяй все три и round-trip.
- Плагины EditMD — только встроенные Swift-типы из `BuiltInPluginRegistry`, с активацией на документ через frontmatter. Не добавляй загрузку JavaScript, внешних bundle или скачанного executable code; semantic token обязан сохранять UTF-16 offsets и пройти Source/Visual/Preview + round-trip.
- Меню добавления плагина живёт в панели «Свойства» правого инспектора (registry-driven). Инсталляция обязана быть undoable, не дублировать уже объявленный блок и корректно встраиваться в существующий frontmatter.
- `.raw` — дословный source of truth для островов. Display-текст таблиц может отличаться, сериализатор читает payload `.raw`.
- Frontmatter не отображается ни в Visual, ни в Preview — им владеет панель «Свойства». Рендер Visual пропускает блок, а координатор препендит verbatim-блок при сериализации через `composeDocumentWithFrontmatter`; байтовая точность блока обязательна.
- Формулы парсятся по маскированному тексту с сохранением UTF-16 offsets; Visual хранит исходный TeX в `.mdMathTex`.
- Rendered-вставки Visual проходят только через `renderForInsertion`, который remap-ит group id. Нативные таблицы перестраиваются через `TableGrid`, island-таблицы — через `replaceTableIsland`.
- Тяжёлые payload нельзя хешировать внутри значений атрибутов NSTextStorage. `MDBlock.hash(into:)` обязан быть O(1).
- `maxNativeTableCells` и `markdownIsHeavy` решают разные задачи и не должны связываться.
- Source display-only выравнивает таблицы через `.kern`; не меняй байты markdown и чисти `.kern` из typing attributes.
- `textView.string = …` и `setAttributedString` синхронно вызывают selection delegate: позицию считывай до замены.
- Presentation-атрибуты Source, меняющие layout, должны быть storage attributes; review wash — temporary layout-manager attributes.

### Paste и изображения

- Special-paste — упорядоченный lazy funnel. **Source:** table → image → plain text. **Visual:** markdown/table → image → plain text. Image detection не должна первой съедать TIFF/PDF-preview из Word/Excel/Numbers.
- Один контекстный guard обслуживает paste и кнопку. Source не вставляет структуру внутри fence; Visual не вставляет её в `codeBlock`, `tableCell` и `.raw`.
- Ошибка сохранения изображения возвращает `false`, чтобы обычный paste получил текстовую часть буфера. Не помечай payload обработанным, если вставка не состоялась.
- `markdownImageSyntax` — общий сериализатор image markdown. `supportedImageMIMETypes` — единый источник расширений, picker types и Preview MIME.
- Assets дедуплицируются по содержимому: сначала размер, затем байты. Не читай каждую картинку целиком без size-фильтра.
- Для textbundle диск определяет существующие assets, `assetsFileWrapper` зеркалится через `addImageAssetWrapper`. При выборе нового имени учитывай любой `fileExists`, включая скрытые файлы и симлинки.
- Image viewer сверяет URL + `mtime` + size и читает файл в detached task. Смена URL очищает чужую картинку и показывает loading; reload того же URL сохраняет старое изображение до результата. Проверка оппортунистическая — при `updateNSView`, не через file watcher.
- Не делай синхронный disk I/O в `updateNSView`/SwiftUI `body`. Paste остаётся синхронным ради честного plain-text fallback, поэтому его файловый scan должен быть минимальным.

### Производительность и UI

- Disk/Process/полный diff не запускаются на main и не вычисляются из SwiftUI `body`. Для папок, git, review anchors и highlight используй cache + background refresh.
- Highlight.js не работает блокирующе на каждом keystroke: editor path использует cache/stale-while-revalidate; blocking допустим для разового HTML/export.
- Light/dark выбирается на отрисовке: dynamic `NSColor`, обе code-палитры, tint формул. Не запекай глобальный `NSApp.effectiveAppearance` в контент окна.
- Номера строк рисуются в левом text inset, не в `NSRulerView`. Геометрия strip/gutter берётся из `EditorFieldGeometry`, не дублируется по режимам.
- `NSTextView.isFlipped == true`. Overlay-вью переиспользуй через pool; add/remove subview из каждого layout создаёт цикл.
- Для Swift 6 AppKit delegate методов, не аннотированных `@MainActor`, используй `nonisolated` + `MainActor.assumeIsolated` только когда AppKit гарантирует main thread.

### Локализация

- Development language — английский; все user-facing строки в коде — английские литералы (SwiftUI-ключи или `String(localized:)` для plain String/AppKit). Русский живёт переводом в `Resources/Localizable.xcstrings`.
- Новая user-facing строка обязана получить ru-перевод в каталоге; формат-спецификаторы перевода должны совпадать с ключом (Int32 в интерполяции кастуй в `Int`).
- Протокольные сообщения MCP/control/логи не локализуются — их читает агент.
- Выбор языка: Settings ▸ General ▸ Language пишет `AppleLanguages` (см. `AppLanguage.swift`), применяется после перезапуска. Тест-хост форсирует en через scheme-аргумент `-AppleLanguages (en)` — строковые ассерты пишутся по-английски.

### Preview, review и integration

- Preview грузится через `loadHTMLString`; schemeless local links обрабатывает JS bridge. Vault-root path начинается с `/`, обычный относительный — от папки документа.
- Настройки активного встроенного плагина редактируются в панели «Свойства» и меняют только registry-whitelisted поля frontmatter (`updateConfiguration`) через обычный undo path — никаких произвольных YAML paths/ranges.
- Review sidecar сохраняет smotr-схему без потерь; offsets — UTF-16. Persist/reload идёт строго FIFO, anchors считаются один раз off-main и кэшируются.
- Физическая смена path сначала получает FIFO permit `ReviewModel`, затем без suspension ставит `AppState` gates и резервирует в `DocumentRegistry` сначала все destinations, потом все sources; завершение обязано передать точные relocate/drop outcomes всем трём координаторам.
- `openDiff` — blocking tool: continuation завершается ровно один раз для Accept/Reject/close/disconnect/timeout.
- IDE/control services не запускаются под XCTest. Control router двухфазный: main state + deferred disk work; socket clients конкурентные и не блокируют main.

## Рабочие правила

- Не редактируй сгенерированный `.xcodeproj` вместо `project.yml`.
- Не смешивай несвязанные изменения и не трогай чужой dirty worktree.
- Общую логику выноси в testable pure/internal functions; paste routing и контекстные guards должны иметь прямые тесты.
- При зависании сначала снимай `sample <pid> 3`, затем оптимизируй подтверждённый hot path.
- Исторические детали, завершённые расследования и списки версий добавляй в `docs/HISTORY.md`, а не раздувай этот файл.

## Известные хвосты

Remote images в Visual, drag-and-drop изображений, поиск внутри Preview и перенос широких ячеек Visual-grid.
