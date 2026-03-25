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

- [x] Обычный текст — monospace, labelColor, без лишних отступов
- [x] Поля 48pt слева и справа
- [x] Длинная строка переносится, не обрезается

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

- [x] H1 — размер ~22pt, bold, отступ сверху 12pt
- [x] H2 — размер ~19pt, bold, отступ сверху 12pt
- [x] H3 — размер ~17pt, bold, отступ сверху 8pt
- [x] H4–H6 — размер ~15pt, bold, отступ сверху 8pt
- [x] Маркеры `#` скрыты когда курсор вне строки

---

## Акцентирование текста

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Bold | `**text**` или `__text__` | шрифт + .bold trait; маркеры `**`/`__` secondary, скрыты вне курсора |
| Italic | `*text*` или `_text_` | шрифт + .italic trait; маркеры `*`/`_` secondary, скрыты вне курсора |
| Bold + Italic | `***text***` или `___text___` | шрифт + (.bold ∪ .italic) trait; маркеры secondary, скрыты вне курсора |
| Strikethrough | `~~text~~` | strikethrough line single, цвет labelColor; маркеры `~~` secondary, скрыты вне курсора |

- [x] **Bold** — визуально жирный
- [x] **Bold** через `__` — то же
- [x] *Italic* — визуально курсивный
- [x] *Italic* через `_` — то же
- [x] ***Bold+Italic*** — оба трейта объединены (не перетирают друг друга)
- [x] ~~Strikethrough~~ — зачёркнутая линия
- [x] Маркеры скрыты когда курсор вне слова

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

- [x] `inline code` — оранжевый, фон-подложка, чуть меньше размер
- [x] `[link](url)` — accent-цвет, синтаксис скрыт вне курсора
- [x] `[link][id]` (reference) — то же оформление, что и inline
- [x] `[id]: url` (definition) — plain text, не подсвечивается
- [x] `![alt](path)` — зелёный alt-текст, синтаксис скрыт вне курсора
- [x] `![alt][id]` (reference image) — то же оформление
- [x] `<br>` inline HTML — tertiary, monospace, чуть меньше размер

---

## Autolinks

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Голый URL | `https://example.com` | весь URL — accent (linkColor); синтаксиса нет, не скрывается |
| Угловые скобки | `<https://example.com>` | текст accent; `<>` — linkSyntax, accent, скрыты вне курсора |
| Email | `user@example.com` | весь адрес — accent; не скрывается |

- [x] Голый URL — целиком accent, виден всегда
- [x] `<url>` — текст accent; угловые скобки скрыты вне курсора
- [x] Email — accent, виден всегда

---

## Переносы строк

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Soft wrap | длинная строка без явного `\n` | NSTextView переносит по ширине, нет markdown-обработки |
| Hard break (2 пробела) | `text  ↵` | cmark → linebreak node; нет SpanKind; рендерится как `\n` |
| Hard break (backslash) | `text\↵` | аналогично — plain `\n` |
| `<br>` как hard break | `<br>` | обрабатывается как `.htmlInline` — tertiary, monospace |

- [x] Soft wrap — перенос без markdown-маркеров
- [x] Hard break через 2 пробела — переход на новую строку
- [x] `<br>` — tertiary-цвет, monospace

---

## Цитаты (Blockquote)

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Blockquote (depth=0) | `> text` | цвет secondary; headIndent=0pt; левая полоса 3pt в secondary-цвете; маркер `>` tertiary, скрыт вне курсора |
| Blockquote (depth=1) | `> > text` | цвет secondary; headIndent=20pt; полоса на x=20; маркер `>>` tertiary, скрыт вне курсора |
| Blockquote (depth=2+) | `> > > text` | headIndent=40pt+ (depth×20pt); полоса на x=40+ |

- [x] Blockquote — левая полоса 3pt, текст secondary
- [x] Вложенный blockquote (depth=1) — полоса смещена на 20pt вправо, текст с отступом 20pt
- [x] Курсор внутри блока — все маркеры `>` видны (block-aware region)
- [x] Маркер `>` скрыт когда курсор вне блока

---

## Code Blocks

| Элемент | Разметка | Визуальное оформление |
|---------|----------|-----------------------|
| Fenced (с языком) | ` ```swift ` | тело: monospace size=base-1, цвет secondary, headIndent=12pt; фон-панель white(0.5, α=0.07); fence-строки скрыты вне курсора; кнопка "swift" в правом верхнем углу |
| Fenced (без языка) | ` ``` ` | то же; кнопка `⎘` вместо названия языка |
| Fenced (тильды) | `~~~` | то же |
| Indented (4 пробела) | `    code` | те же атрибуты, кнопка `⎘` |
| Spacing вокруг блока | — | параграф ДО: paragraphSpacing=16pt; параграф ПОСЛЕ: paragraphSpacingBefore=16pt |

- [x] Фон-панель code block — полуширокий серый прямоугольник с 8pt вертикальными полями
- [x] Код в блоке — monospace, secondary-цвет, отступ 12pt слева
- [x] Fence-строки скрыты когда курсор вне блока
- [x] Кнопка с языком в правом верхнем углу; клик копирует содержимое
- [x] Кнопка `⎘` для блоков без языка
- [x] Отступ 16pt сверху и снизу от соседних параграфов

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

- [x] `---` вне курсора — визуальная линия через strikethrough separatorColor
- [x] `---` на курсоре — виден как tertiary-текст
- [x] Маркеры `-` / `*` / `1.` — accent, скрыты вне строки
- [x] Маркер `1)` (со скобкой) — то же оформление
- [x] Многозначный номер `10.` — то же оформление
- [x] Nested list — маркер accent, отступ не сбивается
- [x] `- [ ]` — маркер скрыт; `[ ]` как plain text
- [x] `- [x]` — маркер скрыт; `[x]` как plain text

---

## Таблицы (редактор)

| Элемент | Визуальное оформление |
|---------|-----------------------|
| Строка заголовка | шрифт + .bold trait (первая строка таблицы) |
| Разделители `\|` | цвет tertiary когда курсор в таблице; скрыты (tinyFont 0.01pt) когда курсор вне таблицы |
| Разделительная строка `\|---|` | tertiary; скрыта вне курсора |
| Ячейки данных | baseFont без изменений (labelColor, monospacedSystemFont) |

- [x] Заголовок таблицы — жирный
- [x] Разделители `|` — tertiary когда курсор в таблице, скрыты вне
- [x] Разделительная строка `|---|` — скрыта вне таблицы

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

- [x] HTML block — tertiary, monospace, чуть меньше размер

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

- [x] `[^1]` — plain text, не подсвечивается
- [x] `$math$` — plain text
- [x] `:smile:` — не заменяется emoji
- [x] HTML-теги внутри таблицы — корректный fallback

---

## Матрица состояний

> Все константы вынесены в `EditorTheme.swift`. Тема `.system` использует системные адаптивные цвета.
> Тема `.comfortable` — те же цвета, увеличенные отступы (editorInsetH=64, codeBlockOuterSpacing=20 и т.д.).

| Цвет/атрибут | `EditorTheme` поле | Адаптируется к темe |
|---|---|---|
| `NSColor.labelColor` | `textColor` | да |
| `NSColor.secondaryLabelColor` | `secondaryColor` | да |
| `NSColor.tertiaryLabelColor` | `tertiaryColor` | да |
| `NSColor.linkColor` | `accentColor` | да |
| `NSColor.systemOrange` | `inlineCodeColor` | да |
| `NSColor.systemGreen` | `imageColor` | да |
| `NSColor.separatorColor` | `separatorColor` | да |
| `NSColor.controlBackgroundColor` | `inlineCodeBackground` | да |
| `NSColor.textBackgroundColor` | фон редактора (NSTextView) | да |
| `NSColor(white:0.5, alpha:0.07)` | `codeBlockBackground` | да (relative) |
| `NSColor(white:0.5, alpha:0.12)` | `copyButtonBackground` | да (relative) |

### Кейсы для проверки

- [ ] Light mode — все цвета корректны *(нужна визуальная проверка)*
- [ ] Dark mode — все цвета корректны (особенно: code block panel виден, inline code background виден) *(нужна визуальная проверка)*
- [x] Курсор внутри block (blockquote/code block) — все маркеры блока видны
- [x] Курсор вне block — маркеры скрыты (invisible + tinyFont)
- [ ] Selection — выделение не конфликтует с подсветкой *(нужна визуальная проверка)*
- [x] Изменение размера шрифта (⌘= / ⌘−) — все атрибуты масштабируются корректно

---

## Сводка покрытия

| SpanKind | Реализован | Визуально корректен |
|----------|-----------|---------------------|
| headingBody(1–6) | [x] | [x] |
| headingMarker | [x] | [x] |
| boldBody / boldMarker | [x] | [x] |
| italicBody / italicMarker | [x] | [x] |
| code (inline) | [x] | [x] |
| linkText / linkSyntax | [x] | [x] |
| quoteBody / quoteMarker | [x] | [x] |
| codeBlockBody / codeBlockFence | [x] | [x] |
| thematicBreak | [x] | [x] |
| listMarker | [x] | [x] |
| imageText / imageSyntax | [x] | [x] |
| htmlInline | [x] | [x] |
| htmlBlock | [x] | [x] |
| strikethroughBody / strikethroughMarker | [x] | [x] |
| tableHeader | [x] | [x] |
| tableDelimiter | [x] | [x] |
| autolink (linkText via GFM extension) | [x] | [x] |
