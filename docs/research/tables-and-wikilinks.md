# Research request: настоящие таблицы в WYSIWYG + wiki-links (Obsidian-style)

Запрос для внешней LLM. Нужен глубокий разбор двух задач в существующем
macOS Markdown-редакторе. Дай конкретные архитектурные варианты **с кодом на
Swift/AppKit**, с трейд-оффами, и рекомендацию под наш случай. Не общие слова —
рабочие паттерны.

---

## 0. Контекст проекта (обязательно к прочтению)

**EditMD** — минималистичный Markdown-редактор для macOS. Чистый SwiftUI App
lifecycle. Свой `DocumentRegistry` (одна модель на URL). Файловый сайдбар с
несколькими workspace-папками (Obsidian-подобная навигация по `.md`).

**Стек:** Swift 6 (strict concurrency, `@MainActor`), AppKit `NSTextView` внутри
`NSViewRepresentable`, парсинг через **`swift-markdown`** (Apple, обёртка над
cmark-gfm; GFM: таблицы, strikethrough, tasklist). TextKit 1 (`NSLayoutManager`,
`allowsNonContiguousLayout = true`).

**Три режима редактора** (переключаются, курсор/скролл сохраняются):

- **Source** — сырой markdown, моноширинный `NSTextView`. Подсветка синтаксиса:
  чистая функция `collectSpans(text) -> [Span]` через `MarkupWalker`
  (swift-markdown) → реальные text-storage атрибуты. Плюс линтер.
- **Visual** — WYSIWYG на attributed-модели. **В тексте НЕТ markdown-маркеров**
  (`#`, `**`, `[]()` не видны); семантика хранится в кастомных атрибутах
  `NSAttributedString`. `isRichText = true`. Пропорциональный шрифт. Таблицы —
  `NSTextTable`, картинки — `NSTextAttachment`. **Каждое изменение синхронно
  сериализуется обратно в markdown** (source of truth — markdown-строка).
- **Preview** — read-only рендер в `WKWebView` через свой HTML-визитор
  (`MarkupWalker` → HTML) + GitHub-подобный CSS.

**Ключевой инвариант Visual — round-trip:**
`serialize(render(markdown)) == нормальная форма markdown`, и
`f(f(x)) == f(x)` (идемпотентность). Есть 55+ round-trip тестов как ворота
качества. Любое изменение модели Visual обязано round-trip'иться без потерь.

### Модель Visual (attributed-атрибуты)

```swift
extension NSAttributedString.Key {
    static let mdBlock  = NSAttributedString.Key("md.block")   // MDBlock (семантика блока)
    static let mdInline = NSAttributedString.Key("md.inline")  // Int битмаска (bold/italic/strike/code)
    static let mdLink   = NSAttributedString.Key("md.link")    // String destination
    static let mdImage  = NSAttributedString.Key("md.image")   // [String: String] src/alt/title
}

struct MDBlock: Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case paragraph
        case heading(Int)
        case codeBlock(language: String)
        case bulletItem(depth: Int)
        case orderedItem(depth: Int, number: Int)
        case taskItem(depth: Int, done: Bool)
        case listContinuation(indent: Int)
        case thematicBreak
        /// Одна ячейка таблицы; ячейки одной таблицы делят `group`.
        case tableCell(row: Int, column: Int, columns: Int, alignment: Int)
        /// Read-only «остров»: сериализуется дословно из хранимого исходника.
        case raw(String)
    }
    var kind: Kind
    var quoteDepth: Int = 0
    var quoteGroup: Int = -1
    var group: Int = -1        // идентичность списка/таблицы/кодоблока
    var listIndent: Int = 0
}
```

Рендер `render(markdown) -> NSAttributedString` — визитор по AST swift-markdown,
проставляет `.mdBlock` на каждый параграф (включая завершающий `\n`).
Презентация (шрифты/цвета/отступы, `NSTextTable`, буллиты) — **производная**,
пересчитывается отдельным проходом `applyPresentation()`; сериализатор читает
ТОЛЬКО семантические атрибуты.

---

## Проблема 1 — большие таблицы не рендерятся как таблицы в Visual

### Что произошло

Файл 342K символов = ОДНА GFM-таблица ~9000 ячеек (5 колонок × 1817 строк).
В Visual каждая ячейка = отдельный `NSTextTableBlock`, и `NSLayoutManager`
раскладывал всю таблицу целиком → **100% CPU бесконечно** (layout super-linear
по числу ячеек; TextKit 1 не виртуализирует).

**Временное решение (уже в коде):** таблицы больше `maxNativeTableCells = 400`
ячеек рендерятся НЕ как `NSTextTable`, а как моноширинный read-only «остров»
(`.raw` — сырой pipe-текст). Открытие: ∞ → ~3.5с. НО теперь **большая таблица
выглядит как моноширинный текст, а не как таблица** — это и есть проблема,
которую надо решить правильно.

Obsidian и FSNotes показывают большие таблицы КАК таблицы без зависания.
(FSNotes, насколько знаю, `NSTextTable` вообще не использует — таблицы у него
моноширинные в редакторе, рендер-таблица только в отдельном preview. Obsidian —
CodeMirror с виртуализацией вьюпорта.)

### Текущий код — фолбэк на остров при рендере

```swift
// MarkdownToAttributed.swift
static let maxNativeTableCells = 400

private func renderTable(_ table: Markdown.Table, ctx: Ctx) {
    let group = nextGroup()
    let alignments = table.columnAlignments
    let columns = max(1, alignments.count)

    // Ранний выход: большая таблица → моноширинный остров (один .raw-параграф),
    // а не тысячи NSTextTableBlock.
    var rowCount = 1
    for _ in table.body.rows {
        rowCount += 1
        if rowCount * columns > Self.maxNativeTableCells {
            renderIsland(table, ctx: ctx)   // → .raw(весь-текст-таблицы)
            return
        }
    }

    // Маленькая таблица — как раньше: по параграфу на ячейку, .mdBlock=.tableCell.
    func renderCell(_ cell: Markdown.Table.Cell, row: Int, column: Int) {
        let kind = MDBlock.Kind.tableCell(row: row, column: column,
                                          columns: columns, alignment: alignmentCode(column))
        appendParagraph(makeBlock(kind, ctx, group: group)) { b in
            self.renderInlines(cell.children, block: b, styles: [], link: nil)
        }
    }
    for (column, cell) in table.head.cells.enumerated() where column < columns {
        renderCell(cell, row: 0, column: column)
    }
    for (rowIndex, row) in table.body.rows.enumerated() {
        for (column, cell) in row.cells.enumerated() where column < columns {
            renderCell(cell, row: rowIndex + 1, column: column)
        }
    }
}
```

### Текущий код — презентация нативной таблицы (NSTextTable)

```swift
// VisualTextView.swift — внутри applyPresentation(), проход по параграфам
var textTables: [Int: NSTextTable] = [:]   // одна NSTextTable на group

switch blockValue.kind {
case .tableCell(let row, let column, let columns, let alignment):
    let table: NSTextTable
    if let existing = textTables[blockValue.group] {
        table = existing
    } else {
        table = NSTextTable()
        table.numberOfColumns = columns
        table.setContentWidth(100, type: .percentageValueType)
        textTables[blockValue.group] = table
    }
    let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                startingColumn: column, columnSpan: 1)
    cell.setBorderColor(theme.separatorColor)
    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
    cell.setWidth(6, type: .absoluteValueType, for: .padding)
    if row == 0 { cell.backgroundColor = NSColor(white: 0.5, alpha: 0.08) }
    style.textBlocks = [cell]
    style.paragraphSpacing = 0
    // выравнивание колонки → style.alignment
// ...
}
```

Замеры (release, БЕЗ layout): `render` большой таблицы ~300мс, сериализация
~130мс. Зависание было именно в **layout** `NSTextView` (раскладка ячеек), а не
в построении attributed-строки. (Отдельная граблю уже пофиксили: `MDBlock`
клался значением в атрибут, а `NSTextStorage` хеширует значения атрибутов при
`fixAttributes` → синтезированный `hash` прогонял весь payload `.raw` → тоже
100% CPU; сделали ручной O(1) `hash(into:)`. Это к сведению.)

### Чего хочу

Большие таблицы (тысячи строк) должны отображаться **как настоящие таблицы** в
Visual (границы, колонки, выравнивание, редактирование ячеек) и при этом
открываться/скроллиться **быстро** (не вешать app). Редактируемость ячеек
желательна, но если придётся сделать большие таблицы read-only ради
производительности — это приемлемый компромисс (маленькие остаются
редактируемыми).

### Вопросы по Проблеме 1

1. **Виртуализация в TextKit.** Реально ли виртуализировать `NSTextTable` в
   `NSTextView` (раскладывать только видимые строки)? Если да — как? Если нет —
   почему архитектурно нельзя, и что тогда.
2. **TextKit 2** (`NSTextLayoutManager` / `NSTextLayoutFragment` /
   `NSTextElement`). Даёт ли переход на TextKit 2 ленивую поячейковую/построчную
   раскладку таблицы из коробки или через кастомный `NSTextLayoutFragment`?
   Насколько это большой рефактор для редактора, где остальное — TextKit 1?
   Можно ли включить TextKit 2 точечно только для таблиц?
3. **NSTextAttachment с кастомной вьюхой.** Вариант: вставлять таблицу как ОДИН
   `NSTextAttachment` с `NSTextAttachmentViewProvider` (macOS 12+), внутри —
   виртуализированный `NSTableView`/`NSScrollView`/SwiftUI-грид с ленивыми
   строками. Плюсы/минусы: как это уживается с редактированием, выделением,
   сериализацией обратно в markdown, курсором между режимами? Дай скелет кода
   (attachment + view provider + datasource, читающий модель таблицы).
4. **Гибрид по порогу.** Маленькие таблицы — `NSTextTable` (как сейчас),
   большие — attachment-с-`NSTableView`. Разумно ли это, где провести порог, и
   как не расплодить два пути сериализации?
5. **Ограниченная нативная таблица.** Можно ли оставить `NSTextTable`, но
   рендерить в storage только первые N строк + строку-«…ещё K строк
   (открыть/редактировать в Source)», подгружая остальное по мере скролла?
   Насколько это хрупко (NSRange-десинхронизация, round-trip)?
6. **Что реально делают Obsidian / Typora / Bear / iA Writer** для больших
   таблиц в редактируемом вью? Какой из подходов масштабируется на 10k+ строк?
7. С учётом нашего инварианта round-trip (модель Visual marker-free,
   сериализация читает только семантические атрибуты) — какой вариант
   **минимально ломает** сериализацию и курсор-маппинг между режимами?

Дай **рекомендованный путь** с эскизом реализации на нашем коде.

---

## Проблема 2 — wiki-links `[[...]]` не поддерживаются

### Текущее состояние

`swift-markdown` (cmark-gfm) НЕ знает синтаксис `[[...]]` — это Obsidian-
расширение, не CommonMark/GFM. Поэтому `[[Note]]`, `[[Note|alias]]`,
`[[Note#heading]]` сейчас во всех трёх режимах — **обычный текст** (никакой
подсветки, не кликабельно, в Preview не ссылка). Наши `.md` полны таких ссылок,
например: `[[doi_10.1001_jama.2013.4997\|📄]]` (обратите внимание — внутри
экранированный `\|` как разделитель alias).

Нужна полноценная поддержка wiki-links **во всех трёх режимах**:
- распознавание `[[target]]`, `[[target|alias]]`, `[[target#heading]]`,
  `[[target#^block]]`;
- визуально — как ссылка (цвет акцента), кликабельно;
- клик → открыть файл `target(.md)` из workspace-папок (у нас есть
  `WorkspaceModel` с деревом папок; резолв по имени файла без расширения, как в
  Obsidian);
- в Source — подсветка синтаксиса;
- в Visual — показывать alias (или target), скрыв `[[`/`]]`/`|`, **но
  round-trip обязан воспроизводить `[[...]]` дословно**;
- в Preview — `<a>` с data-атрибутом, клик перехватывается и роутится в
  открытие файла (а не в браузер).

### Как сейчас проходит ОБЫЧНАЯ ссылка (три режима) — как образец точек интеграции

**Source (`collectSpans` через `MarkupWalker`)** — swift-markdown даёт узел
`Link`, мы эмитим спаны:

```swift
// MarkdownHighlighter.swift — SpanCollector: MarkupWalker
enum SpanKind {
    case linkText(destination: String?), linkSyntax   // + heading/bold/code/...
}

mutating func visitLink(_ link: Link) {
    guard let fullSrc = link.range, let r = nsRange(for: fullSrc) else { descendInto(link); return }
    let childrenArr = Array(link.children)
    if let firstChild = childrenArr.first, let lastChild = childrenArr.last,
       let firstSrc = firstChild.range, let lastSrc = lastChild.range,
       let textRange = nsRange(for: firstSrc.lowerBound..<lastSrc.upperBound) {
        spans.append(Span(range: textRange, kind: .linkText(destination: link.destination)))
        // диапазоны до/после текста ([, ](url)) → .linkSyntax (скрываются вне курсора)
    } else {
        spans.append(Span(range: r, kind: .linkSyntax))
    }
    descendInto(link)
}
```

**Visual (`renderInlines` в MarkdownToAttributed)** — кладём `.mdLink`:

```swift
case let mdLink as Markdown.Link:
    renderInlines(mdLink.children, block: block, styles: styles, link: mdLink.destination ?? "")
// ниже, при формировании атрибутов run'а:
if let link { attrs[.mdLink] = link }
```

Декорация ссылки (цвет) и клик в Visual:

```swift
// applyDerivedInlineDecorations — красим то, что несёт .mdLink
if attrs[.mdLink] != nil {
    storage.addAttribute(.foregroundColor,
                         value: elements.link.color ?? theme.accentColor, range: runRange)
}

// VisualNSTextView.mouseDown — Cmd+click открывает ссылку
if event.modifierFlags.contains(.command), let url = linkURL(at: point) {
    NSWorkspace.shared.open(url); return
}
private func linkURL(at point: NSPoint) -> URL? {
    // hit-test → charIndex → storage.attribute(.mdLink) as String → URL(string:)
    guard /* ... */ let dest = storage.attribute(.mdLink, at: charIndex, effectiveRange: nil) as? String,
          let url = URL(string: dest), url.scheme != nil else { return nil }
    return url
}
```

Сериализация Visual→markdown читает `.mdLink` и восстанавливает `[text](url)`
(стек-алгоритм inline-маркеров). Для wiki-links нужен ДРУГОЙ вывод — `[[...]]`.

**Preview (HTML-визитор через MarkupWalker):**

```swift
mutating func visitLink(_ link: Link) {
    result += "<a"
    if let destination = link.destination { result += " href=\"\(htmlAttributeEscape(destination))\"" }
    result += ">"; descendInto(link); result += "</a>"
}
```

(В Preview уже есть паттерн перехвата кликов: чекбоксы шлют сообщение в
`WKScriptMessageHandler`. Ссылки на файлы можно роутить так же.)

### Ядро проблемы

`swift-markdown` НЕ выдаёт узел для `[[...]]` — он видит внутри `[[Note]]`
обычный текст (или частично `[Note]` как shortcut-ссылку — надо проверить, не
ловит ли парсер `[[` как вложенные скобки). Значит нужен **отдельный слой
распознавания `[[...]]`**, интегрированный до/после swift-markdown, во всех трёх
пайплайнах, не сломав GFM-парсинг и round-trip.

### Вопросы по Проблеме 2

1. **Где парсить `[[...]]`?** Варианты: (а) пост-проход regex по `.string` уже
   после swift-markdown (в `collectSpans` — добавить спаны поверх; в рендере
   Visual — расщепить текстовые run'ы; в HTML — пре/пост-обработка); (б) свой
   inline-парсер/токенайзер вместо/поверх swift-markdown; (в) препроцессинг
   markdown (заменить `[[x]]` на `[x](x)` перед парсингом) — но это ломает
   round-trip и экранирование. Что чище и надёжнее? Дай рекомендацию с кодом.
2. **Коллизии с markdown.** Как корректно НЕ распознать `[[...]]` внутри
   inline-code (`` `[[x]]` ``), fenced-code, и как вести себя, если внутри
   `[[...]]` есть спецсимволы. Как не пересечься с обычными `[text](url)` и
   reference-ссылками `[a][b]`. Регекс-подход vs честный сканер — где грабли?
3. **Экранированный разделитель `\|`.** В наших файлах alias отделён `\|`
   (`[[target\|alias]]`), потому что `|` — разделитель ячеек GFM-таблицы.
   Как это правильно разобрать (target vs alias) и как отличить `\|` внутри
   таблицы от вне её?
4. **Round-trip в Visual (главная сложность).** Модель Visual marker-free.
   Нужен новый атрибут (напр. `.mdWikiLink = "target|alias"`), run показывает
   alias, а сериализатор восстанавливает `[[target|alias]]` дословно (включая
   `\|` при необходимости). Как встроить в стек-алгоритм inline-маркеров, чтобы
   `f(f(x)) == f(x)`? Дай схему кодирования + сериализации.
5. **Резолв target → файл.** Obsidian-семантика: `[[Note]]` резолвится по имени
   файла (без пути и расширения) по всему vault, с обработкой неоднозначности и
   `#heading`/`#^block`. У нас есть `WorkspaceModel` (дерево workspace-папок).
   Как дёшево строить/кешировать индекс имя→URL по большому vault (у нас 7000+
   `.md` в 693 подпапках) и инвалидировать его? Нужен ли `FSEvents`-вотчер?
6. **Клик и «несуществующая» ссылка.** Как открывать резолвнутый файл в нашем
   `DocumentRegistry`/окне (а не в браузере), и как визуально отличать
   ссылку на существующий файл от «висячей» (как Obsidian красит несуществующие
   иначе)? Как быть с `#heading` — скролл к заголовку после открытия.
7. **Autocomplete `[[` (опционально).** Стоит ли сразу закладывать popover-
   автодополнение имён файлов при вводе `[[`, и как это делают в NSTextView?

Дай **рекомендованную архитектуру** wiki-links: единый модуль
распознавания/резолва + точки интеграции в каждый из трёх режимов, с примерами
кода на нашей модели (спаны для Source, `.mdWikiLink`-атрибут + сериализация для
Visual, HTML+перехват клика для Preview).

---

## Общие ограничения (учесть в ответе)

- **Swift 6 strict concurrency**, `@MainActor`-изоляция для UI/AppKit. Никаких
  Combine-подписок в модели (используем notification/явные вызовы).
- Зависимость **`swift-markdown`** (Apple) уже в проекте; менять парсер целиком
  нежелательно, но добавить пост/пре-проходы можно.
- **Round-trip Visual — священный инвариант** (55+ тестов). Любое предложение
  для Visual обязано его сохранять; покажи, как.
- Бизнес-логику выносим в **чистые функции** (тестируемые через `@testable`),
  а не в координаторы NSView.
- Производительность: цель — открытие/скролл файла с таблицей на 10k строк
  без фризов главного потока; подсветка Source сейчас не инкрементальна
  (`collectSpans` по всему тексту) — если предложение это учитывает, тем лучше.
- Диагностику зависаний ведём через `sample <pid>` (стек живого процесса),
  не догадки.

**Формат ответа:** по каждой проблеме — 2-4 конкретных варианта с кодом,
таблица трейд-оффов, одна явная рекомендация под наш стек, и порядок внедрения
(что сделать первым, что можно отложить). Без общих рассуждений — рабочие
паттерны AppKit/TextKit/swift-markdown.
