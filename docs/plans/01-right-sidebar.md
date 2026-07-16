# План 01 — Правый сайдбар: каркас, Outline, Info

Статус: сделано
Зависимости: нет
Разблокирует: 02 (вкладки Ссылки/Backlinks), 04 (Properties), 05 (История)

Выполнено (2026-07-16):
- [x] Этап 1 — каркас панели (`InspectorSidebar`, resize, AppStorage, ⌥⌘0)
- [x] Этап 2 — переезд Outline + миграция `sidebarTab == "outline"` → `"files"`
- [x] Этап 3 — вкладка Info (`FileInfoStats`, disk/git, заглушка Связи)

## Цель

Правая боковая панель для **document-scope** функций — всего, что относится к текущему
открытому файлу. Левый сайдбар остаётся про workspace (Files, Tags, Git). В этом разделе:

1. Каркас панели: показ/скрытие, resize, персистентность, полоса табов.
2. Переезд Outline из левого сайдбара в правый.
3. Новая вкладка Info: факты о текущем файле.

После раздела в левом сайдбаре остаются Files / Git / Review / Tags (Review переедет позже,
план 08), в правом появляются Outline / Info.

## Контекст и существующий код

Прочитай перед началом: `CLAUDE.md`, `docs/HISTORY.md` (разделы про сайдбар и layout).

- `EditMD/EditMD/Views/ContentView.swift` — layout главного окна. Левый сайдбар монтируется
  примерно в строках 104–128: `@AppStorage("sidebarVisible")`, `@AppStorage("sidebarWidth")`
  (диапазон `150...400`), `@AppStorage("sidebarTab")`, 12pt grab strip для resize
  (см. комментарий «agterm's sidebar-divider lesson»), `.focusedSceneValue(\.sidebarVisible, …)`.
  Правая панель делается по тому же образцу, зеркально.
- `EditMD/EditMD/Views/WorkspaceSidebar.swift` — устройство левой панели: `navigatorToolbar`
  (Xcode-style иконки табов), `switch tab` (строки ~218–233), `bottomBar` (+ / Filter / eye),
  фон `Color(nsColor: .windowBackgroundColor)`. Тут Outline удаляется из `switch`.
- `EditMD/EditMD/Views/OutlineSidebar.swift` — сам Outline; переиспользуется как есть,
  меняется только место монтирования. Сигнатура: `OutlineSidebar(content:filter:onJump:)`.
- `EditMD/EditMD/Views/FocusedValues.swift` — образец проброса команд меню.
- `EditMD/EditMD/Views/SidebarRows.swift`, `SidebarChrome` (в WorkspaceSidebar.swift) —
  общие стили строк и отступов; правые вкладки обязаны использовать их же.
- `EditMD/EditMD/Views/FolderInfo.swift` — `scanFolderTreeStats` + кэш с epoch: образец
  «cache + background refresh» для статистики Info.
- `EditMD/EditMD/Views/GitSidebar.swift` / `GitUI.swift` — откуда брать git-статус файла.
- ContentView передаёт в WorkspaceSidebar `outlineContent` и `onJump` — эти же данные
  понадобятся правой панели.
- Lite-окна (`ContentView` с `allowsSidebar == false`) не показывают левый сайдбар. Правый
  сайдбар в lite-окнах **показывать можно** (он document-scope), но вкладки, требующие
  workspace (в будущем — Backlinks), обязаны корректно работать без workspace.

## Архитектурные решения

- **Новый файл** `EditMD/EditMD/Views/InspectorSidebar.swift` — контейнер правой панели
  (табы + переключение содержимого). Имя «Inspector» по аналогии с Xcode; не путать с
  будущими вкладками.
- Отдельные AppStorage-ключи: `inspectorVisible` (по умолчанию false), `inspectorWidth`
  (по умолчанию 220, диапазон как у левого), `inspectorTab` (по умолчанию `"outline"`).
- Табы — строковые ключи как в левом сайдбаре (`"outline"`, `"info"`), без enum, чтобы
  AppStorage-миграций не было.
- Toggle-команда в меню View: «Показать/скрыть инспектор», шорткат ⌥⌘0 (Xcode-привычка;
  проверь, что не конфликтует с существующими commands в `EditMD/EditMD/App/`).
  Через `.focusedSceneValue`, по образцу `\.sidebarVisible`.
- Миграция таба: если у пользователя `sidebarTab == "outline"`, при первом запуске после
  обновления левый таб сбрасывается в `"files"` (иначе `switch` упадёт в `default` — это
  и так Files, но сделай явно и оставь комментарий).
- Info-вкладка читает статистику **не из SwiftUI body**: факты о файле (размер, mtime,
  git-статус) собираются в фоне и кэшируются, обновление — оппортунистическое при смене
  документа/появлении вкладки (образец — image viewer и `FolderTreeStats`).
- Счёт слов/символов считается от текущей markdown-строки документа (она уже в памяти),
  но с дебаунсом на ввод (не на каждый keystroke).

## Этапы

### Этап 1 — каркас панели

1. `InspectorSidebar.swift`: VStack с полосой табов сверху (иконки как `navigatorToolbar`)
   и контентом; фон и отступы — те же `SidebarChrome`.
2. В `ContentView.swift` смонтировать панель справа от editor-области, зеркально левой:
   ширина из `inspectorWidth`, 12pt grab strip **слева** от панели, анимация показа как у
   левой (`.easeInOut(duration: 0.15)`).
3. Команда меню View + шорткат, `.focusedSceneValue`.
4. Пока одна вкладка-заглушка Info с текстом пути файла — чтобы этап собирался и был виден.

Проверка этапа: сборка, запуск, панель открывается/закрывается, resize работает, ширина
переживает перезапуск.

### Этап 2 — переезд Outline

1. В `InspectorSidebar` добавить таб `"outline"`, монтировать `OutlineSidebar` с теми же
   параметрами, что сейчас в `WorkspaceSidebar`.
2. Правой панели нужен свой фильтр-инпут для Outline: перенеси паттерн `filterText` /
   `bottomBar` из левой панели (без «+» и «eye» — только Filter).
3. Удалить case `"outline"` из `WorkspaceSidebar` и иконку из `navigatorToolbar`;
   добавить сброс `sidebarTab == "outline"` → `"files"`.
4. Все места, открывающие Outline программно (поиск по `sidebarTab = "outline"` — если
   есть), перевести на `inspectorTab`.

### Этап 3 — вкладка Info

Секции сверху вниз:

- **Файл**: имя, относительный путь от корня workspace (или полный для loose-файлов),
  кнопка «Скопировать путь» (в старом todo уже была для контекстного меню — переиспользуй
  реализацию), размер, дата изменения.
- **Документ**: слова, символы, строки, заголовки (кол-во из `MarkdownOutline`),
  line endings (LF/CRLF/mixed) и наличие финального newline.
- **Git**: clean/modified/untracked для текущего файла (переиспользуй машинерию GitSidebar,
  не запускай новый Process на main).
- **Связи** (задел под план 02): строка «Ссылки: — / Backlinks: —» с заглушкой; план 02
  заменит на счётчики.

Статистику собирает `struct FileInfoStats` + чистая функция `computeFileInfoStats(text:)`
(тестируемая), файловая часть — в detached task с кэшем по (url, mtime).

## Тесты

- Unit: `computeFileInfoStats` — слова/символы/строки/line endings на LF, CRLF, mixed,
  пустом файле, файле без финального newline.
- Unit: миграция `sidebarTab == "outline"` → `"files"`.
- Существующие Outline-тесты (если завязаны на WorkspaceSidebar) — поправить монтирование.
- Полный suite + `git diff --check`.

## Критерии приёмки

- Правая панель: открытие/закрытие из меню и шорткатом, resize, персистентность ширины,
  таба и видимости.
- Outline работает справа во всех режимах (Source / Visual / Preview / Split), переход по
  клику на заголовок работает; слева Outline больше нет.
- Info показывает корректные факты, не вызывает подвисаний на больших файлах
  (проверить на файле из `docs/research/` — большие таблицы).
- Lite-окно: правая панель доступна, Outline и Info работают без workspace.
- Light/dark: панель корректна в обеих темах (dynamic NSColor, без запекания appearance).

## Инварианты и запреты

- Не редактируй `.xcodeproj` — только `EditMD/project.yml`, затем
  `xcodegen generate --spec EditMD/project.yml` (новые файлы в существующей папке Views
  подхватываются без правки project.yml, но xcodegen прогони).
- Никакого синхронного disk I/O и Process в SwiftUI `body` / `updateNSView`.
- Геометрия editor-области меняется — проверь, что `EditorFieldGeometry` (полосы, gutter)
  не сломались при открытой правой панели, особенно в Split.
- Не смешивай в один коммит каркас, переезд Outline и Info — три этапа, три коммита.

## Верификация

```bash
xcodegen generate --spec EditMD/project.yml
xcodebuild -project EditMD/EditMD.xcodeproj -scheme EditMD -destination 'platform=macOS' build
xcodebuild -project EditMD/EditMD.xcodeproj -scheme EditMD -destination 'platform=macOS' test
```

Скриншоты снять нельзя (`screencapture` в этом окружении недоступен) — запусти собранное
приложение и опиши пользователю, что проверить глазами: открытие панели, resize, Outline
справа, Info-факты, обе темы, Split-режим.
