# Визуальный аудит EditMD — три режима (v34 / app 0.34.3)

Статус по **коду** (не ручной light/dark-прогон).\
`[x]` = реализовано и ожидаемо работает · `[ ]` = gap / не сделано · `[~]` = частично (см. примечание).

**Файл для smoke:** `test-all-elements.md`\
**Дополнительно:** vault-карточка с YAML + `[[wiki]]`, heavy-таблица.

---

## Переключение режимов

- [x] Три кнопки режима в тулбаре (Source / Visual / Preview) + ⌘1 / ⌘2 / ⌘3 (View-меню)
- [x] Курсор сохраняется Source ↔ Visual (`EditorPositionStore`)
- [x] Вьюпорт центрируется на курсоре; фокус ввода в редакторе
- [x] Preview — пропорциональный скролл на первом рендере
- [x] Последний режим восстанавливается (`@AppStorage("editorMode")`)
- [x] Сплит редактор+превью (⌥⌘P); live Preview с дебаунсом

---

## Source (⌘1)

Сырой markdown, моноширинный. С v27 — подсветка по ElementStyles + линт temporary underlines.

### Подсветка и layout

- [x] H1–H6: размер/вес/цвет (строка целиком, включая `# `)
- [x] Bold / italic / strike / inline-code / link text
- [x] Wiki-links `[[Note]]` / `[[Note|alias]]` (inner accent, syntax secondary)
- [x] ```` ```yaml ```` / ```` ```yml ````: токены ключ/число/bool/null/коммент
- [x] YAML frontmatter: не setext-H2; тело yaml; фенсы приглушены
- [x] Таблицы: виртуальный `.kern` (пайпы в столбик, файл не меняется)
- [x] Длинная ячейка > cap: рваная строка, остальные колонки держат ширину
- [x] Heavy-документ: plain mono, без подсветки/линта (антифриз)
- [x] Built-in multi-checkbox: все описанные frontmatter-статусы подсвечиваются; core checkbox-lint для активного файла отключён

### Линт

- [x] Пунктир: красный error / оранжевый warning
- [x] Tooltip (temporary `.toolTip`)
- [x] ПКМ quick-fix (напр. `- [+]` → `[x]` / `[ ]`)
- [x] Fix + ⌘Z (shouldChangeText / didChangeText)
- [x] Бейдж в статус-строке → jump to next по кругу

### Форматирование

- [x] ⌘B / ⌘I → `**` / `*`
- [x] Format-меню: strike, code span, ⌥⌘1–6, списки, цитата, code block

---

## Visual (⌘2)

### Базовый рендер

- [x] H1–H6 размер/вес; divider под H1/H2
- [x] Bold / italic / strike / inline-code без маркеров
- [x] Ссылки + Cmd+click → браузер
- [x] Списки: буллиты / номера / чекбоксы в марджине
- \[\~\] Вложенность: indent по depth есть; **форма буллита одна** на все depth (не •/◦/▪)
- [x] Цитаты: полосы + indent по глубине
- [x] Код-блоки: панель + mono
- [ ] ```` ```yaml ```` в Visual: токен-цвета (есть в Source/Preview; Visual — mono)
- [x] `---` — горизонтальная линия
- [x] HTML-остров mono, read-only; удаление целиком — ок
- [x] Setext → нормальная форма ATX при round-trip

### Таблицы

**Малые (≤ \~400 ячеек) — NSTextTable**

- [x] Грид, шапка, выравнивания
- [x] Редактирование ячеек; Tab / Shift+Tab
- [x] Enter вниз / выход с пустой последней строки
- [x] Backspace не сливает ячейки

**Большие (island) — virtualized grid**

- [x] Рисуется как таблица (не pipe-текст)
- [x] Inline md в ячейках (bold/italic/strike/code/link/wiki)
- [x] Двойной клик / F2 — overlay-редактор + GFM round-trip
- [x] H-scroll (Shift+wheel / horizontal gesture)
- [ ] Wrap широких ячеек (сейчас truncate + fixed row height)

### Картинки / wiki / frontmatter

- [x] Local image (.md рядом / textbundle), cap \~420pt
- \[\~\] Missing / remote → placeholder `photo` (**async remote load — нет**)
- [x] `[[Note]]` / `[[Note|alias]]` display + Cmd+click → файл
- [ ] Unresolved wiki: другой цвет (сейчас как валидная + beep)
- [x] Frontmatter: read-only карточка свойств (YAML colors)
- [x] Правка frontmatter только в Source

### Ввод

- [x] Enter продолжает список (ordered +1, task → unchecked)
- [x] Enter на пустом пункте — выход
- [x] Tab / Shift+Tab / Backspace outdent
- [x] Автоформат `- ` / `1. ` / `[] ` / `## `; fence+Enter → code block
- [x] ⌘B / ⌘I; ⌘⇧L чеклист; ⌘K ссылка
- [x] Клик по чекбоксу + undo
- [x] Built-in multi-checkbox: SF Symbol/emoji, цикл кликом + undo, list/prose/table; strike-state зачёркивает list item
- [x] Паста = plain text

### Синхронизация

- [x] Visual → Source: актуальный нормализованный markdown
- [x] ⌘S без смены режима
- [x] Live Preview в сплите (дебаунс, scroll preserve)

---

## Preview (⌘3)

### Рендер

- [x] Заголовки, inline, списки, цитаты, HR
- [x] Таблицы (HTML)
- [x] Код-блоки + ```` ```yaml ```` токены
- [x] Local images (data-URI); remote как URL
- [x] Frontmatter → таблица свойств
- [x] Wiki-links → клик открывает файл
- [x] `==highlight==` → `<mark>`
- [x] Light/dark без reload (`color-scheme` + system colors)

### Интерактив

- [x] Чекбоксы кликабельные → пишут в source
- [x] Built-in multi-checkbox кликабельный в списках, тексте и таблицах → циклически пишет следующий frontmatter-статус в source
- [x] Enter → Visual (полный Preview)
- [x] http(s)-ссылки → браузер, Preview не уезжает
- [x] Счётчик слов/символов в статус-строке

### `==highlight==` вне Preview

- [ ] Visual: semantic highlight (background), без `==` в display
- [ ] Source: цвет/фон для `==…==` (сейчас только wrap из меню)

---

## Темы и настройки

- [x] Preset: System / GitHub (Comfortable удалён → маппится на System)
- [x] Appearance: System / Light / Dark, персист
- [x] Смена темы/overrides без рестарта
- [x] Settings ⌘,: per-mode font / insets / column / ElementStyles
- [x] Plugins tab: read-only список встроенных Swift-плагинов и их frontmatter keys
- [x] Source = mono families; Visual/Preview = proportional
- [x] `columnWidth` 0 = full, >0 = centered column

---

## Сайдбар и навигация

- [x] Files / Outline (⌃⌘S); клик = replace в main window
- [x] Outline jump → offset (Source/Visual/Preview)
- [x] Wiki-link → main window (bias на папку документа)
- [x] Back / Forward ⌘\[ / ⌘\]
- [ ] `[[Note#heading]]` / `#^block` — scroll после открытия (файл открывается, fragment игнор)
- [ ] `[[` autocomplete

---

## Light / dark matrix

Код адаптивный (dynamic NSColor / `color-scheme`). **Ручной** pixel-check не прогонялся этой сессией:

| Область | Light | Dark |
| --- | :-: | :-: |
| Source: heading/code/link | \[\~\] | \[\~\] |
| Source: lint underlines | \[\~\] | \[\~\] |
| Visual: quote / code / table | \[\~\] | \[\~\] |
| Visual: wiki + links | \[\~\] | \[\~\] |
| Preview: body + code + FM | \[\~\] | \[\~\] |
| Preview: `<mark>` | \[\~\] | \[\~\] |
| Selection / caret contrast | \[\~\] | \[\~\] |

`[~]` = реализовано в коде (adaptive colors); глазами light+dark не верифицировано.

---

## Known gaps (открытые)

| Gap | Где | Статус |
| --- | --- | --- |
| `==highlight==` display style | Visual, Source | Preview only |
| Unresolved wiki style | все режимы | beep, цвет как у валидной |
| Remote images async | Visual | placeholder |
| YAML tokens in code block | Visual | mono |
| Large-table cell wrap | Visual island | truncate |
| Nested bullet glyphs by depth | Visual | один oval |
| Code lang label + copy | Visual | нет |
| Frontmatter property widgets | Visual | read-only card |
| Heavy Source viewport highlight | Source | full plain |
| Heading/block scroll after wiki | nav | fragment ignored |
| `[[` autocomplete | ввод | нет |
| Preview find | Preview | нет |

**Отложено (не рендер):** undo через режимы; CRUD столбцов; drag&drop картинок; per-document mode.

---

## Сводка

| Область | Готово | Частично | Gaps |
| --- | :-: | :-: | :-: |
| Режимы / split / курсор | ✓ |  |  |
| Source подсветка + линт + kern | ✓ | heavy=plain | highlight `==` |
| Visual базовый WYSIWYG | ✓ | bullets depth | yaml code, remote img |
| Visual таблицы (small + large) | ✓ | H-scroll ✓ | cell wrap |
| Wiki / frontmatter | ✓ | unresolved style | #heading scroll |
| Preview | ✓ |  | find, unresolved style |
| Темы / Settings | ✓ |  |  |
| Light/dark pixel-pass |  | code only | ручной прогон |
