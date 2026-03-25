# Visual Audit: Markdown Elements in EditMD

Чекбоксы: `- [ ]` не соответствует / не проверено, `- [x]` соответствует.

---

## Базовый текст

| Элемент | Визуальное оформление |
|---------|-----------------------|
| Обычный параграф | monospacedSystemFont(ofSize: base, weight: .regular); цвет labelColor; фон textBackgroundColor |
| Отступы редактора | textContainerInset = 48pt слева/справа, 24pt сверху/снизу |
| Межстрочный интервал | default NSParagraphStyle (lineSpacing=0, paragraphSpacing=0) |
| Перенос длинной строки | NSTextView soft-wrap по ширине контейнера, без горизонтального scroll |

- [ ] Обычный текст — monospace, labelColor, без лишних отступов
- [ ] Поля 48pt слева и справа
- [ ] Длинная строка переносится, не обрезается

---

## Заголовки

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| H1 | `# Heading` | system bold, size=base+8 (base≈14 → ~22pt), spacingBefore=12pt, spacingAfter=4pt; маркер `#` tertiary, скрыт вне курсора |
| H2 | `## Heading` | system bold, size=base+5 (~19pt), spacingBefore=12pt, spacingAfter=4pt |
| H3 | `### Heading` | system bold, size=base+3 (~17pt), spacingBefore=8pt, spacingAfter=4pt |
| H4 | `#### Heading` | system bold, size=base+1 (~15pt), spacingBefore=8pt, spacingAfter=4pt |
| H5 | `##### Heading` | system bold, size=base+1 (~15pt), spacingBefore=8pt, spacingAfter=4pt |
| H6 | `###### Heading` | system bold, size=base+1 (~15pt), spacingBefore=8pt, spacingAfter=4pt |

- [ ] H1 — размер ~22pt, bold, отступ сверху 12pt
- [ ] H2 — размер ~19pt, bold, отступ сверху 12pt
- [ ] H3 — размер ~17pt, bold, отступ сверху 8pt
- [ ] H4–H6 — размер ~15pt, bold, отступ сверху 8pt
- [ ] Маркеры `#` скрыты когда курсор вне строки

---

## Акцентирование текста

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Bold | `**text**` или `__text__` | шрифт + .bold trait; маркеры `**`/`__` secondary, скрыты вне курсора |
| Italic | `*text*` или `_text_` | шрифт + .italic trait; маркеры `*`/`_` secondary, скрыты вне курсора |
| Bold + Italic | `***text***` или `___text___` | шрифт + (.bold ∪ .italic) trait; маркеры secondary, скрыты вне курсора |
| Strikethrough | `~~text~~` | strikethrough line single, цвет labelColor; маркеры `~~` secondary, скрыты вне курсора |

- [ ] **Bold** — визуально жирный
- [ ] **Bold** через `__` — то же
- [ ] *Italic* — визуально курсивный
- [ ] *Italic* через `_` — то же
- [ ] ***Bold+Italic*** — оба трейта объединены (не перетирают друг друга)
- [ ] ~~Strikethrough~~ — зачёркнутая линия
- [ ] Маркеры скрыты когда курсор вне слова

---

## Инлайн-элементы

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Inline code | `` `code` `` | monospacedSystemFont, size=base-1, цвет systemOrange, фон controlBackgroundColor |
| Link (inline) | `[text](url)` | текст accent (NSColor.linkColor); синтаксис `[](url)` accent, скрыт вне курсора |
| Link (reference) | `[text][id]` | cmark разрешает до рендера → те же SpanKind: текст accent; синтаксис accent, скрыт вне курсора |
| Определение ссылки | `[id]: url` | нет SpanKind (cmark не генерирует AST-узел для definition); plain text |
| Image (inline) | `![alt](path)` | alt-текст systemGreen; синтаксис `![]()` systemGreen, скрыт вне курсора |
| Image (reference) | `![alt][id]` | CMARK_NODE_IMAGE; те же SpanKind: alt systemGreen; синтаксис скрыт вне курсора |
| Inline HTML | `<br>`, `<em>` | monospacedSystemFont, size=base-1, цвет tertiary |

- [ ] `inline code` — оранжевый, фон-подложка, чуть меньше размер
- [ ] `[link](url)` — accent-цвет, синтаксис скрыт вне курсора
- [ ] `[link][id]` (reference) — то же оформление, что и inline
- [ ] `[id]: url` (definition) — plain text, не подсвечивается
- [ ] `![alt](path)` — зелёный alt-текст, синтаксис скрыт вне курсора
- [ ] `![alt][id]` (reference image) — то же оформление
- [ ] `<br>` inline HTML — tertiary, monospace, чуть меньше размер

---

## Autolinks

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Голый URL | `https://example.com` | весь URL — accent (linkColor); синтаксиса нет, не скрывается |
| Угловые скобки | `<https://example.com>` | текст accent; `<>` — linkSyntax, accent, скрыты вне курсора |
| Email | `user@example.com` | весь адрес — accent; не скрывается |

- [ ] Голый URL — целиком accent, виден всегда
- [ ] `<url>` — текст accent; угловые скобки скрыты вне курсора
- [ ] Email — accent, виден всегда

---

## Переносы строк

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Soft wrap | длинная строка без явного `\n` | NSTextView переносит по ширине, нет markdown-обработки |
| Hard break (2 пробела) | `text  ↵` | cmark → linebreak node; нет SpanKind; рендерится как `\n` |
| Hard break (backslash) | `text\↵` | аналогично — plain `\n` |
| `<br>` как hard break | `<br>` | обрабатывается как `.htmlInline` — tertiary, monospace |

- [ ] Soft wrap — перенос без markdown-маркеров
- [ ] Hard break через 2 пробела — переход на новую строку
- [ ] `<br>` — tertiary-цвет, monospace

---

## Цитаты (Blockquote)

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Blockquote (depth=0) | `> text` | цвет secondary; headIndent=0pt; левая полоса 3pt в secondary-цвете; маркер `>` tertiary, скрыт вне курсора |
| Blockquote (depth=1) | `> > text` | цвет secondary; headIndent=20pt; полоса на x=20; маркер `>>` tertiary, скрыт вне курсора |
| Blockquote (depth=2+) | `> > > text` | headIndent=40pt+ (depth×20pt); полоса на x=40+ |

- [ ] Blockquote — левая полоса 3pt, текст secondary
- [ ] Вложенный blockquote (depth=1) — полоса смещена на 20pt вправо, текст с отступом 20pt
- [ ] Курсор внутри блока — все маркеры `>` видны (block-aware region)
- [ ] Маркер `>` скрыт когда курсор вне блока

---

## Code Blocks

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Fenced (с языком) | ` ```swift ` | тело: monospace size=base-1, цвет secondary, headIndent=12pt; фон-панель white(0.5, α=0.07); fence-строки скрыты вне курсора; кнопка "swift" в правом верхнем углу |
| Fenced (без языка) | ` ``` ` | то же; кнопка `⎘` вместо названия языка |
| Fenced (тильды) | `~~~` | то же |
| Indented (4 пробела) | `    code` | те же атрибуты, кнопка `⎘` |
| Spacing вокруг блока | — | параграф ДО: paragraphSpacing=16pt; параграф ПОСЛЕ: paragraphSpacingBefore=16pt |

- [ ] Фон-панель code block — полуширокий серый прямоугольник с 8pt вертикальными полями
- [ ] Код в блоке — monospace, secondary-цвет, отступ 12pt слева
- [ ] Fence-строки скрыты когда курсор вне блока
- [ ] Кнопка с языком в правом верхнем углу; клик копирует содержимое
- [ ] Кнопка `⎘` для блоков без языка
- [ ] Отступ 16pt сверху и снизу от соседних параграфов

---

## Разделители и списки

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Thematic break (на курсоре) | `---` / `***` / `___` | цвет tertiary |
| Thematic break (вне курсора) | `---` / `***` / `___` | цвет separatorColor + горизонтальная линия (strikethrough) |
| List marker — unordered `-` | `- item` | цвет accent (linkColor); скрыт вне строки-курсора |
| List marker — unordered `*` | `* item` | то же |
| List marker — ordered `.` | `1. item` | accent; скрыт вне строки |
| List marker — ordered `)` | `1) item` | accent; скрыт вне строки |
| List marker — multi-digit | `10. item` / `100. item` | accent; скрыт вне строки |
| Nested list (2+ уровня) | `  - nested` | маркер accent; отступ через NSTextView default (без headIndent) |
| Многострочный item | item с переносом | нет SpanKind для body; plain text под item |
| Task list `[ ]` | `- [ ]` | маркер `-` accent, скрыт вне строки; `[ ]` — plain text (нет SpanKind для чекбокса) |
| Task list `[x]` | `- [x]` | то же; `[x]` — plain text |

- [ ] `---` вне курсора — визуальная линия через strikethrough separatorColor
- [ ] `---` на курсоре — виден как tertiary-текст
- [ ] Маркеры `-` / `*` / `1.` — accent, скрыты вне строки
- [ ] Маркер `1)` (со скобкой) — то же оформление
- [ ] Многозначный номер `10.` — то же оформление
- [ ] Nested list — маркер accent, отступ не сбивается
- [ ] `- [ ]` — маркер скрыт; `[ ]` как plain text
- [ ] `- [x]` — маркер скрыт; `[x]` как plain text

---

## Таблицы (редактор)

| Элемент | Визуальное оформление |
|---------|-----------------------|
| Строка заголовка | шрифт + .bold trait (первая строка таблицы) |
| Разделители `\|` | цвет tertiary когда курсор в таблице; скрыты (tinyFont 0.01pt) когда курсор вне таблицы |
| Разделительная строка `\|---|` | tertiary; скрыта вне курсора |
| Ячейки данных | baseFont без изменений (labelColor, monospacedSystemFont) |

- [ ] Заголовок таблицы — жирный
- [ ] Разделители `|` — tertiary когда курсор в таблице, скрыты вне
- [ ] Разделительная строка `|---|` — скрыта вне таблицы

---

## Таблицы (Preview)

Используется `.gitHub` theme (swift-markdown-ui):

| Элемент | Визуальное оформление |
|---------|-----------------------|
| Заголовок | bold + фоновый цвет header row (GitHub theme) |
| Ячейки | системный шрифт, видимые border-рамки, padding ~6–12pt |
| Разделительная строка | не отображается (только border CSS) |
| Выравнивание | через синтаксис `:---`, `---:`, `:---:` |

- [ ] Preview — заголовок bold с фоном
- [ ] Preview — видимые границы ячеек
- [ ] Preview — левое выравнивание по умолчанию

---

## HTML Block

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| HTML block | `<div>...</div>` | monospacedSystemFont size=base-1, цвет tertiary |

- [ ] HTML block — tertiary, monospace, чуть меньше размер

---

## Неподдерживаемый синтаксис (fallback)

Парсер подключает только: `strikethrough`, `table`, `tasklist`, `autolink`.
Всё остальное рендерится как plain text без подсветки.

| Синтаксис | Разметка | Ожидаемый результат |
|-----------|----------|---------------------|
| Footnote | `[^1]` / `[^1]: text` | plain text, не подсвечивается |
| Math inline | `$x^2$` | plain text |
| Math block | `$$...$$` | plain text |
| Admonition | `:::note` | plain text |
| Emoji shortcode | `:smile:` | plain text (`:smile:` как есть) |
| Nested tables | таблица внутри ячейки | не поддерживается cmark-gfm |
| Definition list | `term\n: definition` | plain text |

- [ ] `[^1]` — plain text, не подсвечивается
- [ ] `$math$` — plain text
- [ ] `:smile:` — не заменяется emoji
- [ ] HTML-теги внутри таблицы — корректный fallback

---

## Матрица состояний

| Цвет/атрибут | Использование | Адаптируется к темe |
|---|---|---|
| `NSColor.labelColor` | базовый текст | да |
| `NSColor.secondaryLabelColor` | blockquote, code block body, bold/italic markers | да |
| `NSColor.tertiaryLabelColor` | heading markers, quote markers, thematic break (active), table delimiter | да |
| `NSColor.linkColor` | ссылки, list markers | да |
| `NSColor.systemOrange` | inline code | да |
| `NSColor.systemGreen` | image alt + syntax | да |
| `NSColor.separatorColor` | thematic break (inactive) | да |
| `NSColor.controlBackgroundColor` | inline code background | да |
| `NSColor.textBackgroundColor` | фон редактора | да |
| `NSColor(white:0.5, alpha:0.07)` | code block panel | да (relative) |

### Кейсы для проверки

- [ ] Light mode — все цвета корректны
- [ ] Dark mode — все цвета корректны (особенно: code block panel виден, inline code background виден)
- [ ] Курсор внутри block (blockquote/code block) — все маркеры блока видны
- [ ] Курсор вне block — маркеры скрыты (invisible + tinyFont)
- [ ] Selection — выделение не конфликтует с подсветкой
- [ ] Изменение размера шрифта (⌘= / ⌘−) — все атрибуты масштабируются корректно

---

## Сводка покрытия

| SpanKind | Реализован | Визуально корректен |
|----------|-----------|---------------------|
| headingBody(1–6) | [x] | [ ] |
| headingMarker | [x] | [ ] |
| boldBody / boldMarker | [x] | [ ] |
| italicBody / italicMarker | [x] | [ ] |
| code (inline) | [x] | [ ] |
| linkText / linkSyntax | [x] | [ ] |
| quoteBody / quoteMarker | [x] | [ ] |
| codeBlockBody / codeBlockFence | [x] | [ ] |
| thematicBreak | [x] | [ ] |
| listMarker | [x] | [ ] |
| imageText / imageSyntax | [x] | [ ] |
| htmlInline | [x] | [ ] |
| htmlBlock | [x] | [ ] |
| strikethroughBody / strikethroughMarker | [x] | [ ] |
| tableHeader | [x] | [ ] |
| tableDelimiter | [x] | [ ] |
| autolink (linkText via GFM extension) | [x] | [ ] |
