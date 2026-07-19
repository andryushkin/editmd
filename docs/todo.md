# TODO

Задачи сгруппированы по зоне кода, чтобы выполнять группами за один заход.

> Граф знаний кодовой базы: `graphify-out/` (4174 узла, 159 сообществ; `graph.html` — интерактив). Для структурных вопросов «что с чем связано» — `graphify query "…"` вместо ручного обхода. NB: рантайм-семантику SwiftUI (view-identity `.id`, teardown) граф не показывает — только типы/функции/вызовы.

## Группа A — Сайдбар и поиск по workspace

Зона: `WorkspaceSidebar` / `WorkspaceSearchSidebar` / `WorkspaceSearchModel` / `SearchMatch.swift`.

- [x] Files-сайдбар: выбор файла из середины списка при открытии скачком прокручивал сайдбар к началу папки; сбрасывались `selectedFiles`/`filterText` (2026-07-18). **Корень:** `MainWindowView` вешал `.id(currentURL)` на `FileEditor`, при каждом открытии уничтожая и пересоздавая всё поддерево вместе с `WorkspaceSidebar` → `ScrollView` терял offset. `.id` нужен для acquire/release документа в `DocHost`. **Сделано 2026-07-19 (подход 2 «hoist», внешнее ревью подтвердило разрез):** сайдбар вынесен из `.id`-свопаемой ветки в стабильный `MainChrome` (`FileEditor.swift`) — chrome живёт, `.id`-свопается только центр. Схлопнуты 4 копии сайдбара (ContentView / PDFViewerView / FolderInfo / WelcomeView) в одну; `sidebarVisible`/`sidebarWidth` + divider + toolbar-toggle + `focusedSceneValue(\.sidebarVisible)` — теперь один раз в `MainChrome`; `onOpen`-модалка «уже открыт в другом окне» вынесена в свободную `openFileFromWorkspaceSidebar`. Clamp разделён по сторонам (main: sidebar; ContentView: inspector). Инспектор остался в ContentView (document-scoped). Lite-окна (`allowsSidebar:false`) без `MainChrome` — как раньше. `DocHost`/undo/registry НЕ тронуты. ScrollViewReader из смягчения оставлен как safety-net (anchor `nil` — подскролл только для off-screen активного файла). Сборка + 1126 XCTest + 73 Swift Testing зелёные. **Глазами НЕ проверено — smoke:** (1) длинная папка → клик середина → scroll/filter/multiselect живы; (2) search → open hit → scroll не в 0; (3) .md→pdf→folder→welcome→.md — сайдбар не мигает, tab/filter на месте; (4) ⌃⌘S на каждой ветке; (5) resize sidebar+inspector у min-окна; (6) lite-окно без workspace-сайдбара.
- [ ] Поиск по workspace: горячие следы (`_opaqueCharacterStride`, `String.lowercased`, `Substring.index(before:)`) были сняты, когда параллельно жёг vault-lint — после его фикса (2be2133) перемерить на чистом сценарии, прежде чем оптимизировать. Идея на случай подтверждения: case-insensitive поиск по UTF-8 байтам без lowercased-копий (профиль 2026-07-18, WoL-вольт 6919 md). **Уточнение через graphify (2026-07-19):** цепочка `runWorkspaceSearch` (`SearchMatch.swift:288`) → `searchContentMatches` (:206). Единственная горячая точка — `searchTextContains` (:109) = Foundation `range(of:options:.caseInsensitive)`; **явных `.lowercased()`-копий в hot path НЕТ** — следы `_opaqueCharacterStride`/lowercased идут из внутреннего casefold Foundation. Тело фолдится повторно: `allSatisfy { searchTextContains(text, needle) }` по всему телу (:221) **плюс** пер-строчный цикл `searchTextOccurrenceCount` по каждой строке×needle (:238–265). UTF-8-байтовый lowercase рискует кириллицей — Foundation-фолдинг именно поэтому и выбран (коммент :107–108). **Вывод (2026-07-19): блайнд-фикс НЕ делать — это ловушка.** «Убрать двойной проход» на деле регрессирует общий путь: whole-body `allSatisfy` — быстрый reject, для НЕ-совпадающих файлов (большинство на волте) делается один проход и пер-строчный line-scan пропускается (`runWorkspaceSearch` вызывает `searchContentMatches` только для прошедших meta-фильтр, а внутри line-scan только при `matched`). Если вывести `matched` из пер-строчного прохода — не-совпадающие файлы получат полный line-scan вместо раннего reject → медленнее. Реальная стоимость — необходимый whole-body casefold-скан по всем файлам; сначала профайл на чистом волте, потом решать.

## Группа B — Layout и toolbar в сплит-режиме

Зона: геометрия сплитов `ContentView`/инспектор, toolbar сплита.

- [x] Layout при малой ширине окна: правый инспектор наползал на соседние панели, границы панелей перекрывались (2026-07-18). — Сделано 2026-07-19: `resolveSidePaneWidths` + `preferredPaneWidthFromDrag`; floor окна `mainWindowMinWidth` **900** / lite 560 через `NSWindow.contentMinSize` (`applyWindowContentMinimum` — SwiftUI `.frame(minWidth:)` на `Window` не держит live resize). 720 на практике ещё mid-word-wrap при двух панелях 220. Тесты: `PaneLayoutTests`.
- [ ] В сплит-режиме панель инструментов может быть не свёрнутой и может быть на весь экран, в том числе и над review-частью. **Локализовано через graphify (2026-07-19):** это `EditorActionStrip` (`EditorActionStrip.swift`), у него overflow-схлопывание через `.plan()` (:215) / `.measurementLayer()` (:237) / `.overflowPill()` (:281) / `StripWidthKey` (:695) + `.reduce()`. В `ContentView.editorArea` strip стоит в VStack **над** обеими панелями и получает `editingPaneWidth: mode == .split ? splitEditorWidth : nil` (`ContentView.swift:421`) — то есть бар полноширинный (над Preview-«review» частью тоже), а его кнопки лишь выравниваются по source-колонке. Проверить: (1) почему `.plan()` не схлопывает при узкой source-панели; (2) не ограничить ли ширину strip самой source-панелью в split. **Вывод (2026-07-19): это дизайн-намерение, не явный баг.** Коммент `EditorActionStrip.swift:96-98`: «the strip itself is wider — it spans Source + Preview»; инструменты уже зажаты в source-полосу (`toolLaneWidth = min(laneBeforeMode, laneInsideEditor)`), mode-switch намеренно у дальнего края (над Preview). Хотим ли ограничить бар source-панелью в split — твой дизайн-выбор поведения; блайнд-менять намеренную раскладку не стал. Нужны глаза + решение по желаемому виду.
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
