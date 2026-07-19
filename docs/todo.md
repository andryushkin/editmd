# TODO

Задачи сгруппированы по зоне кода, чтобы выполнять группами за один заход.

> Граф знаний кодовой базы: `graphify-out/` (4174 узла, 159 сообществ; `graph.html` — интерактив). Для структурных вопросов «что с чем связано» — `graphify query "…"` вместо ручного обхода. NB: рантайм-семантику SwiftUI (view-identity `.id`, teardown) граф не показывает — только типы/функции/вызовы.

## Группа A — Сайдбар и поиск по workspace

Зона: `WorkspaceSidebar` / `WorkspaceSearchSidebar` / `WorkspaceSearchModel` / `SearchMatch.swift`.

- [ ] Files-сайдбар: в папке с большим числом файлов выбор файла из середины списка при открытии скачком прокручивает сайдбар к началу папки (2026-07-18). То же самое в поиске по workspace: выбор файла из результатов — скачок прокрутки вверх. **Корень найден (2026-07-19):** `MainWindowView` вешает `.id(currentURL)` на `FileEditor` (`FileEditor.swift`), поэтому при каждом открытии файла SwiftUI уничтожает и пересоздаёт всё поддерево — включая `ContentView` → `WorkspaceSidebar`, — и `ScrollView` теряет offset (заодно сбрасываются `@State` сайдбара: `selectedFiles`, `filterText`). `.id` нужен для acquire/release документа в `DocHost`. **Фикс архитектурный:** либо вынести сайдбар из `.id`-свопаемой ветки (в `MainWindowView`), либо заставить `DocHost` менять документ in-place по `onChange(of: url)` вместо пересоздания. Требует плана + проверки глазами. **graphify (2026-07-19)** подтвердил lifecycle: `DocumentRegistry.acquire()` (`DocumentStore.swift:203`) / `.parkInSessionCache()` (:824) — на этом держится `.id`-teardown; SwiftUI view-identity как ребро в графе не представлена, поэтому сам корень нашёлся чтением кода, не графом.
- [ ] Поиск по workspace: горячие следы (`_opaqueCharacterStride`, `String.lowercased`, `Substring.index(before:)`) были сняты, когда параллельно жёг vault-lint — после его фикса (2be2133) перемерить на чистом сценарии, прежде чем оптимизировать. Идея на случай подтверждения: case-insensitive поиск по UTF-8 байтам без lowercased-копий (профиль 2026-07-18, WoL-вольт 6919 md). **Уточнение через graphify (2026-07-19):** цепочка `runWorkspaceSearch` (`SearchMatch.swift:288`) → `searchContentMatches` (:206). Единственная горячая точка — `searchTextContains` (:109) = Foundation `range(of:options:.caseInsensitive)`; **явных `.lowercased()`-копий в hot path НЕТ** — следы `_opaqueCharacterStride`/lowercased идут из внутреннего casefold Foundation. Тело фолдится повторно: `allSatisfy { searchTextContains(text, needle) }` по всему телу (:221) **плюс** пер-строчный цикл `searchTextOccurrenceCount` по каждой строке×needle (:238–265). Безопасный выигрыш (Cyrillic-safe сохраняется): убрать двойной проход — «matched» вывести из пер-строчного прохода, а не сканировать всё тело отдельно. UTF-8-байтовый lowercase рискует кириллицей — Foundation-фолдинг именно поэтому и выбран (коммент :107–108).

## Группа B — Layout и toolbar в сплит-режиме

Зона: геометрия сплитов `ContentView`/инспектор, toolbar сплита.

- [x] Layout при малой ширине окна: правый инспектор наползал на соседние панели, границы панелей перекрывались (2026-07-18). — Сделано 2026-07-19: `resolveSidePaneWidths` + `preferredPaneWidthFromDrag`; floor окна `mainWindowMinWidth` **900** / lite 560 через `NSWindow.contentMinSize` (`applyWindowContentMinimum` — SwiftUI `.frame(minWidth:)` на `Window` не держит live resize). 720 на практике ещё mid-word-wrap при двух панелях 220. Тесты: `PaneLayoutTests`.
- [ ] В сплит-режиме панель инструментов может быть не свёрнутой и может быть на весь экран, в том числе и над review-частью. **Локализовано через graphify (2026-07-19):** это `EditorActionStrip` (`EditorActionStrip.swift`), у него overflow-схлопывание через `.plan()` (:215) / `.measurementLayer()` (:237) / `.overflowPill()` (:281) / `StripWidthKey` (:695) + `.reduce()`. В `ContentView.editorArea` strip стоит в VStack **над** обеими панелями и получает `editingPaneWidth: mode == .split ? splitEditorWidth : nil` (`ContentView.swift:421`) — то есть бар полноширинный (над Preview-«review» частью тоже), а его кнопки лишь выравниваются по source-колонке. Проверить: (1) почему `.plan()` не схлопывает при узкой source-панели; (2) не ограничить ли ширину strip самой source-панелью в split. Нужны глаза.
- [ ] В сплит-режиме когда экран с прокруткой и печатаешь на последней строке — экран Source дёргается. **Локализовано через graphify (2026-07-19):** `SplitScrollSync` (`SplitScrollSync.swift`), цикл caret-follow: `.visibleParagraphAnchor()` (:69) → `.scrollViewport()` (:94), демпфер дрожания уже есть — `.isMinorLayoutDrift()` (:32, окно ≤4px). На последней строке caret-follow конкурирует с anchor-follow → петля обратной связи выходит за 4px. Нужен живой репро + глаза; при повторении логировать `visibleParagraphAnchor.fraction` и proposed origin.

## Группа C — Редактирование в Source / Visual

Зона: editor input, native/island-таблицы, авто-продолжение списков.

- [ ] Visual: не работает редактирование больших таблиц (2026-07-18, найдено при проверке CPU-фикса LinkIndex на WoL-вольте). Уточнить репро: размер таблицы и что именно не работает (ввод в ячейку? сериализация?). Вероятная зона: порог `maxNativeTableCells` → island-таблица (`replaceTableIsland`); смежный известный хвост — перенос широких ячеек Visual-grid.
- [ ] В сплит- и Source-режиме: при нажатии Enter внутри списков и чекбоксов автоматически вставлять продолжение (маркер/`- [ ]`). Наверное и с таблицами так же.

## Группа D — Git-панель UI

Зона: Git-сайдбар.

- [ ] Кнопку commit приходится нажимать два раза.
- [ ] Кнопку push сделать серой, done — синей, и поменять их местами.

## Группа E — Инфраструктура и диагностика

- [ ] Встроить логирование — сейчас при печати проценты приближаются к 100% загрузки процессора, нужен инструмент, чтобы это ловить.
- [ ] (наблюдение, НЕ баг-фикс) «Preview не перерендерился после удаления строки» — не воспроизведено; при повторении вернуть NSLog-цепочку `syncToDocument → updateNSView → render`.

## Группа F — Темы (отложено)

Пользователь (2026-07-18): «старую удали, потом сделаем пресеты для source и visual». Старая система выбора удалена (спринт 3, app 0.45.0). Полная унификация через ThemeSpec отложена.

- [ ] Полноценные пресеты для Source и Visual поверх baseline (возможно ThemeSpec + проекции). Единый пикер, `ElementStyles`/`fontFamily` fallback’и в тему, «Reset to theme».
