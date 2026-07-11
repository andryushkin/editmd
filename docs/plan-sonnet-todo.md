# План кодинга по docs/todo.md — для исполнителя уровня Sonnet

> Разбор `docs/todo.md` (41 пункт) от 2026-07-11. Каждая задача — самостоятельная карточка
> с файлами-якорями, шагами и критерием готовности. Пункты, требующие решения человека
> или слишком рискованные для авто-исполнения, вынесены в раздел «Отложено».

## Правила исполнителя (обязательно)

1. **Перед стартом** прочитай `CLAUDE.md` целиком. Перед задачей в зоне конкретной версии —
   соответствующий раздел `docs/HISTORY.md` (в карточках указано, какой).
2. **Сборка/тесты:**
   ```bash
   cd EditMD
   xcodegen generate          # ТОЛЬКО если добавлял/удалял файлы или менял project.yml
   xcodebuild -scheme EditMD -destination "platform=macOS" build
   xcodebuild -scheme EditMD -destination "platform=macOS" -enableCodeCoverage NO test
   ```
   `-enableCodeCoverage NO` обязателен, иначе linker error.
3. **Одна задача = один коммит** (`fix:`/`feat:`/`refactor:` + номер карточки). Push не делать.
4. **Версию приложения не трогать** без отдельного указания.
5. **Инварианты из CLAUDE.md не нарушать.** Самые частые для этого плана:
   - сайдбар не ходит на диск синхронно из SwiftUI body (кэш + фоновый скан);
   - Source-подсветка = storage-атрибуты; review-wash = temporary; не смешивать;
   - правки в Visual — через restamp-паттерн (`shouldChangeText` → mutate → `didChangeText`);
   - round-trip держит `.raw` — сериализатор не «улучшать» без тестов;
   - никаких O(текст×N) вычислений на кейстрок — кэши уже есть, использовать их.
6. **Если код противоречит карточке** (якорь не найден, поведение иное) — остановись,
   опиши расхождение, не импровизируй.
7. Порядок батчей произвольный, порядок ВНУТРИ батча — как написано (есть зависимости).

---

## Сводный triage todo.md

| todo (строка) | Вердикт | Карточка |
|---|---|---|
| 3 копировать путь | в работу | A1 |
| 4 плагины | отложено (архитектура) | X1 |
| 5 картинки | отложено (нет скоупа) | X2 |
| 6 файл для проверки разметки | в работу | D7 |
| 7 claude создаёт workspace | в работу | D6 |
| 8 переименовать workspace | в работу | A2 |
| 9 рефакторинг тулбара | в работу | B1 |
| 10 тёмный/светлый режим | отложено (нужно репро) | X3 |
| 11 номера строк в preview | в работу (репро→фикс) | C1 |
| 12 экспорт в pdf | в работу | D3 |
| 13 просмотр pdf | отложено (архитектура) | X4 |
| 14 галочка номера строк | в работу | D1 |
| 15 нижняя панель прижать вниз | в работу | A3 |
| 16 теги, вкладка | в работу (последней) | D11 |
| 17 значок копирования | в работу | D4 |
| 18 цветная разметка кода | отложено (выбор подхода) | X5 |
| 19 комментирование через тег | отложено (дизайн) | X6 |
| 20 формулы | отложено (скоуп) | X7 |
| 21 темы ×6 | в работу | D10 |
| 22 workspace-закрепление по умолчанию | отложено (решение автора) | X8 |
| 23 split синхронизация | в работу | D5 |
| 24 finder → lite окно | в работу | C5 |
| 25 редактор ссылок | в работу | D9 |
| 26 линтер в status bar | в работу | D2 |
| 27 подсветка корневой папки | в работу | A6 |
| 28 подсветка строк исчезает | в работу (репро→фикс) | C2 |
| 29 AI-вкладка в sidebar | отложено (дизайн) | X9 |
| 30 info папки: все подпапки | в работу | D8 |
| 31 Visual: лишние пустые строки | в работу (тест→фикс) | C4 |
| 32 Visual: Enter после заголовка | в работу | C3 |
| 33 Visual: вставка markdown | отложено (рискованная зона) | X10 |
| 34 активное форматирование в тулбаре | в работу | B6 |
| 35 кнопка «обычный текст» | в работу | B4 |
| 36 кнопка РЕГИСТР | в работу | B5 |
| 37 закладки-комментарии | отложено («на подумать») | X11 |
| 38 кнопка линия-разделитель | в работу | B3 |
| 39 таблицы: CRUD столбцов | отложено (NSTextTable, риск) | X12 |
| 40 кнопка \`код\` | в работу | B2 |
| 41 панель Files по умолчанию | в работу | A4 |
| 42 «+»/Filter к панели Files | в работу | A5 |
| 43 tombstones review-меток | отложено (согласование со smotr) | X13 |

---

## Батч A — сайдбар, мелочи (низкий риск, S)

### A1 · «Скопировать путь» в контекстном меню
**Файлы:** `EditMD/EditMD/Views/WorkspaceSidebar.swift` — пять `.contextMenu`: ~300 (корень workspace), ~358 (fileRow), ~384 (looseRow), ~490 (папка в SubfolderNode), ~535 (nestedFileRow).
**Сделать:** во все пять меню добавить пункт «Скопировать путь»:
`NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)`.
Чтобы не дублировать 5 раз — вынести в маленький helper (например, `func copyPathMenuItem(_ url: URL) -> some View`).
**Готово:** правый клик по файлу/папке/loose-файлу → пункт есть, путь в буфере.

### A2 · Переименование workspace
**Файлы:** `EditMD/EditMD/Views/WorkspaceModel.swift:15` (`struct Workspace`), `WorkspaceSidebar.swift` (contextMenu корня ~300).
**Сделать:** в `Workspace` добавить `var customName: String?` (synthesized Codable декодирует отсутствующий optional как nil — старый персист не сломается); `var name` → `customName ?? url.lastPathComponent`. В contextMenu корня — «Переименовать…» → `alert` с `TextField` (macOS 13+ поддерживает TextField в alert); пустая строка = сброс на имя папки. Персист сработает сам через `didSet` на `workspaces`.
**Готово:** переименовал → имя в сайдбаре сменилось, пережило перезапуск; сброс работает.

### A3 · Нижняя панель сайдбара прижата вниз
**Файлы:** `WorkspaceSidebar.swift:26-55` (body: VStack → Group(switch tab) → bottomBar).
**Сделать:** на `Group` с контентом вкладки повесить `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)` — тогда bottomBar всегда у нижнего края, даже если контент вкладки короткий.
**Готово:** на всех четырёх вкладках при коротком контенте панель +/Filter/глаз внизу.

### A4 · При запуске всегда вкладка Files
**Файлы:** `WorkspaceSidebar.swift:21` (`@AppStorage("sidebarTab") private var tab = "files"`), `EditMD/EditMD/App/EditMDApp.swift` или `AppDelegate.swift` (точка старта).
**Сделать:** НЕ убирать `@AppStorage` (сброс на @State потеряет вкладку при пересоздании вью внутри сессии). Вместо этого один раз при старте приложения: `UserDefaults.standard.set("files", forKey: "sidebarTab")` (в `applicationDidFinishLaunching` или init AppDelegate).
**Готово:** переключил на Git → перезапустил app → открыта Files; внутри сессии вкладка держится.

### A5 · «+» относится к панели Files
**Файлы:** `WorkspaceSidebar.swift:141-155` (`bottomBar`, Menu с «New Workspace…»).
**Сделать:** обернуть `+`-Menu в `if tab == "files"` (по образцу eye-кнопки ниже, ~178). **Filter оставить на всех вкладках** — он реально фильтрует Outline/Git/Review (см. комментарий к `filterText`). В коммит-сообщении отметить: «Filter оставлен глобальным — фильтрует все вкладки; убрать = 1 строка, если автор имел в виду иначе».
**Готово:** `+` виден только в Files; фильтр работает как раньше.

### A6 · Подсветка корневой папки активного файла
**Файлы:** `WorkspaceSidebar.swift:252` (`workspaceGroup(_ ws:)`), проп `activeURL`.
**Сделать:** если `activeURL?.path.hasPrefix(ws.folderPath + "/") == true` — выделить заголовок workspace (например, имя `.fontWeight(.semibold)` + точка/иконка акцентным цветом; посмотреть, как `isActive(_:)` (:397) красит активный файл, и сделать в том же стиле).
**Готово:** открыт файл из workspace A → заголовок A визуально выделен, B — нет; loose-файл → ничего не выделено.

---

## Батч B — тулбар и форматирование (порядок важен: B1 первым)

### B1 · Рефакторинг тулбара: вынести из ContentView (refactor, M)
**Файлы:** `EditMD/EditMD/Views/ContentView.swift:455+` (`toolbarContent` + соседние helpers) → новый `EditMD/EditMD/Views/EditorToolbar.swift`.
**Сделать:** механический перенос: `struct EditorToolbar: ToolbarContent` c `@Binding`/`let`-пропами вместо прямого доступа к @State ContentView. Поведение не менять ни на пиксель. После добавления файла — `xcodegen generate`.
**Готово:** сборка зелёная, все кнопки/меню тулбара работают как до рефакторинга (режимы, тема, ☀/🌙, сайдбар, сплит).

### B2 · Кнопка inline-кода `` ` `` (S)
**Файлы:** `EditMD/EditMD/Editor/FormattingHelpers.swift` (`applyWrap` — уже есть, покрыт `FormattingHelpersTests`), `EditMD/EditMD/Views/FocusedValues.swift` (FormatActions), `EditorToolbar.swift`, Format-меню в `EditMDApp.swift`.
**Сделать:** проверить, есть ли уже действие inline-code в FormatActions (Format-меню полное с v25) — если есть, только кнопка в тулбар; если нет — добавить действие через `applyWrap` с `` ` `` в обоих режимах (Visual — через VisualCoordinatorFormat, там есть inline-توggle'ы) + кнопка + пункт меню.
**Готово:** выделение → кнопка → обёрнуто в backticks (Source) / моноширинный span (Visual); повторное нажатие снимает.

### B3 · Кнопка «линия-разделитель» (S-M)
**Файлы:** `EditorToolbar.swift`, FormatActions, `SourceTextView.swift`, `EditMD/EditMD/Editor/VisualCoordinatorFormat.swift`.
**Сделать:** действие «Insert Divider»: Source — вставить `\n\n---\n\n` на курсоре через `shouldChangeText`/`didChangeText` (undo). Visual — сначала изучи `VisualCoordinatorFormat.swift`: если есть вставка блочного элемента — использовать её; если нет — вставить новый параграф-блок thematic break тем же путём, каким Enter создаёт новые блоки (см. handleEnter в `VisualTextView.swift:832+`). Если в Visual выходит рискованно — оставить кнопку задизейбленной в Visual и написать об этом в коммите.
**Готово:** в Source кнопка вставляет `---` отдельным блоком, undo работает; round-trip тест не ломается.

### B4 · Кнопка «обычный текст» — снять форматирование (M)
**Файлы:** `FormattingHelpers.swift` + `FormattingHelpersTests.swift`, `VisualCoordinatorFormat.swift`, тулбар/меню.
**Сделать:** новое действие clearFormatting(selection):
- **Source:** чистая функция `stripInlineMarkers(String) -> String` — снять `**`/`*`/`` ` ``/`~~` в выделении (написать СНАЧАЛА тесты: жирный, вложенный жирный+курсив, код с backtick внутри — не трогать содержимое кода). Замена через `shouldChangeText`.
- **Visual:** через format-путь снять inline `md.*`-атрибуты выделения и вернуть базовый шрифт (по образцу существующих toggle'ов в VisualCoordinatorFormat + правило union-трейтов из CLAUDE.md).
**Готово:** тесты helper'а зелёные; в обоих режимах выделение становится плоским текстом; заголовок/список НЕ разжаловывается (только inline).

### B5 · Кнопка РЕГИСТР (S-M)
**Файлы:** `FormattingHelpers.swift` (+тесты), тулбар/меню.
**Сделать:** чистая функция циклической смены регистра выделения: UPPER → lower → Capitalized → UPPER (определять текущее состояние по содержимому). Применение — заменой выделенного текста через `shouldChangeText`/`didChangeText` (в Visual замена строки сохраняет атрибуты диапазона — проверить руками на жирном фрагменте).
**Готово:** тесты на цикл (включая кириллицу «привет»→«ПРИВЕТ»); undo возвращает исходник.

### B6 · Тулбар показывает активное форматирование (M)
**Файлы:** `SourceTextView.swift` (Coordinator, `textViewDidChangeSelection`), `VisualTextView.swift` (Coordinator, то же), `FocusedValues.swift`, `EditorToolbar.swift`.
**Сделать:** структура `ActiveInlineFormats { bold, italic, code, strikethrough: Bool }`. Source: по позиции курсора найти охватывающие span'ы в **кэше** `cachedSpans` (НЕ пересчитывать collectSpans — инвариант). Visual: прочитать `md.*`-атрибуты по курсору из storage. Прокинуть наверх тем же путём, каким уже идёт lint-summary (`onLintUpdate` в `ContentView.swift:379` — скопировать паттерн: closure-callback → @State → в тулбар). Кнопки B/I/код красить `Color.accentColor` при активном формате.
**Грабли:** `textViewDidChangeSelection` дёргается синхронно при установке текста (инвариант v22) — guard на `isMutating`/`isInternalUpdate` как в соседнем коде.
**Готово:** курсор в `**bold**` → кнопка B подсвечена; вне — нет; в Visual то же; печать не тормозит (никаких новых парсов на кейстрок).

---

## Батч C — багфиксы (сначала репро, потом фикс)

### C1 · Номера строк в Preview (репро → фикс, S-M)
**Файлы:** `EditMD/EditMD/Views/MarkdownPreviewView.swift:199` (`showLineNumbers: g.showLineNumbers`), генерация HTML в `MarkdownHTML.swift`, `GutterSettings` (`EditorSettings.swift:396`).
**Сделать:** 1) воспроизвести: файл с заголовками/кодом/таблицей — чем номера в Preview отличаются от Source (сдвиг? пропуски? не те строки?). 2) Записать репро в коммит. 3) Починить маппинг (в Preview номера должны соответствовать строкам исходного markdown; у блоков уже есть md-offset теги — см. `scrollToMdOffset`).
**Готово:** номер строки заголовка в Preview == номеру в Source на том же документе; тест в `MarkdownHTMLTests` на разметку номеров, если номера генерятся в HTML.

### C2 · Подсветка изменённых строк «потихоньку исчезает» в новом файле (репро → фикс, M)
**Файлы:** `EditMD/EditMD/Editor/LineChangeTracker.swift`, `LineNumberRulerView.swift:293` (обновление руллера), `DocumentStore.swift` (autosave).
**Контекст:** метки — session-only, baseline = открытие файла или external apply (док-коммент `GutterSettings`). Подозрение: autosave/собственный flush заново принимает текущий контент за baseline → метки гаснут.
**Сделать:** 1) репро: новый файл, печатать, ждать autosave — гаснут ли метки. 2) найти, кто вызывает установку baseline (grep по LineChangeTracker: кто зовёт reset/baseline) — свой flush НЕ должен сбрасывать baseline (по аналогии с инвариантом v34: свой flush ≠ external change). 3) фикс + ручная проверка.
**Готово:** метки живут до закрытия файла/external apply, autosave их не гасит.

### C3 · Visual: Enter в конце заголовка → обычный текст (S-M)
**Файлы:** `VisualTextView.swift:56-73` (`continuationKind` — для heading уже возвращает nil = plain), `:832+` (handleEnter), `VisualCoordinatorPresentation.swift`.
**Контекст:** kind нового параграфа уже plain — значит баг в том, что новый параграф наследует **презентационные атрибуты** заголовка (крупный шрифт через `typingAttributes`).
**Сделать:** репро; затем в ветке Enter-в-конце-блока после вставки новой строки сбросить `typingAttributes` на базовые (шрифт/цвет body) — там же, где ставится kind нового блока.
**Готово:** `# Заголовок` → Enter → печатаю → обычный текст; сериализация даёт `# Заголовок\n\nтекст` без мусора; round-trip тесты зелёные.

### C4 · Visual сам добавляет пустые строки (тест → фикс, M, аккуратно)
**Файлы:** `EditMD/EditMD/Editor/AttributedToMarkdown.swift`, `MarkdownToAttributed.swift`, `EditMDTests/RoundTripTests.swift` (55 кейсов — образец).
**Сделать:** 1) СНАЧАЛА падающие тесты: фикстуры (заголовок+текст, списки, цитата, код, таблица, frontmatter) → render → serialize → **строгое равенство** и второй прогон (идемпотентность). Найти, какие фикстуры дают лишние `\n`. 2) Локализовать в сериализаторе, где добавляется лишний разделитель. 3) Минимальный фикс.
**Грабли:** зона round-trip ворот (v20) — менять ТОЛЬКО то, что чинит тесты; `.raw`-острова не трогать; все 55+ старых кейсов должны остаться зелёными.
**Готово:** новые тесты зелёные, старые зелёные, ручная проверка: открыть файл → Visual → ничего не печатать → переключить в Source → диффа нет.

### C5 · Открытие через Finder → lite-окно (S)
**Файлы:** `EditMD/EditMD/App/AppState.swift:84` (роутинг по `general.liteMode`), `AppDelegate.swift:35`, `EditorSettings.swift:383` (default false).
**Сделать:** 1) проверить руками: включить liteMode в Settings ▸ General, открыть .md из Finder — открывается ли отдельное окно без сайдбара. 2) Если работает — пункт todo означает смену умолчания: в decode/init `liteMode` default → `true`. 3) Если НЕ работает — починить роутинг (см. `docs/HISTORY.md` § v28 про WindowGroup(for: URL)).
**Готово:** двойной клик в Finder на чистой конфигурации → lite-окно; открытие из сайдбара по-прежнему в главном окне.

---

## Батч D — фичи (S → L, в этом порядке)

### D1 · View-меню: показать/скрыть номера строк (S)
**Файлы:** `EditMDApp.swift` (commands, View-меню — рядом с ⌘1/⌘2/⌘3), `EditorSettings.swift:396` (`GutterSettings.showLineNumbers` — уже существует и уже применяется во всех режимах).
**Сделать:** Toggle-пункт «Line Numbers» в View-меню, биндинг на `EditorSettings.shared` (посмотреть, как SettingsView мутирует настройки, и сделать так же — редакторы уже реагируют на изменения, v27).
**Готово:** пункт меню мгновенно скрывает/показывает gutter в Source/Visual и номера в Preview; галочка отражает состояние; Settings-окно синхронно.

### D2 · Линтер: значок в статус-баре (S-M)
**Файлы:** `ContentView.swift:30` (`lintSummary`), `:547` (текущий показ только в source), `MarkdownLint.swift`.
**Сделать:** постоянный значок в статус-баре для Source-режима: иконка + число проблем (0 → приглушённая галочка). Клик → popover со списком: правило, строка, текст; клик по строке → jump (путь jump уже есть — `onJump` у сайдбара); кнопка quick-fix у правил с фиксом (fix-применение уже есть в линтере, v19).
**Готово:** значок живёт в статус-баре, обновляется при правках, popover кликабелен.

### D3 · Экспорт в PDF (M)
**Файлы:** новый `EditMD/EditMD/Editor/PDFExporter.swift`, File-меню в `EditMDApp.swift`, `MarkdownHTML.swift` (`previewHTMLPage`).
**Сделать:** File ▸ «Export as PDF…»: NSSavePanel → offscreen `WKWebView` (фикс. ширина ~800pt) → `loadHTMLString(previewHTMLPage(...), baseURL: папка файла)` (baseURL нужен для локальных картинок) → в `didFinish` вызвать `webView.createPDF { }` → записать data.
**Грабли:** WKNavigationDelegate в macOS 26 SDK — только async-вариант `decidePolicyFor` (инвариант v24); держать сильную ссылку на offscreen webView до завершения; для WKWebView вне window дать `frame` явно.
**Готово:** экспорт документа с заголовками/таблицей/картинкой открывается в Preview.app и читаем.

### D4 · Значок копирования у блоков кода и цитат в Preview (S-M)
**Файлы:** `MarkdownHTML.swift` (HTML-шаблон/CSS/JS `previewHTMLPage`).
**Сделать:** в шаблон добавить JS: на hover над `pre` и `blockquote` показывать кнопку «копировать» (absolute, правый верхний угол); клик → скопировать `innerText` (через `navigator.clipboard.writeText`, fallback `document.execCommand('copy')` если clipboard API в WKWebView не даст разрешение — проверить руками) + галочка на 1с.
**Скоуп:** только Preview. Overlay-кнопки в Source — отдельная задача позже (паттерн button-pooling задокументирован в CLAUDE.md).
**Готово:** hover → кнопка, клик → текст блока в буфере, тёмная/светлая тема ок.

### D5 · Split-режим: синхронизация скролла (M)
**Файлы:** `SourceTextView.swift` (подписка на скролл), `ContentView.swift` (сплит-связка, ~335), `MarkdownPreviewView.swift:518` (`scrollToMdOffset` — уже есть).
**Сделать:** односторонняя синхронизация редактор → превью, только когда сплит открыт: подписка на `NSView.boundsDidChangeNotification` у `contentView` scroll'а редактора (selector-based observer — инвариант про NotificationCenter+@MainActor), debounce ~120мс, взять `characterIndexForInsertion(at: верх видимой области)` через layoutManager → прокинуть offset в preview → `window.scrollToMdOffset(offset)` (fallback на пропорциональный скролл уже встроен).
**Грабли:** не синхронизировать в обратную сторону (петля не возникнет — превью read-only, но и не нужно); при закрытом сплите observer снимать.
**Готово:** скроллю Source в сплите → превью следует за верхним видимым блоком; печать не тормозит.

### D6 · Control-канал: команда создания workspace (M)
**Файлы:** `EditMD/EditMD/Integration/ControlRouter.swift` (+Protocol), `editmdctl/` (CLI), `WorkspaceModel.swift` (метод добавления папки — рядом с `promptAddFolder`), `EditMDTests/ControlChannelTests.swift`.
**Контекст:** пункт todo — «чтобы claude code, открывая файл на ознакомление, мог создать workspace». Канал v38 уже есть.
**Сделать:** команда `workspace.add {path}` по двухфазному паттерну `ControlRouter.process` (валидация пути — deferred на сокет-потоке, мутация WorkspaceModel — main-фаза). Путь только абсолютный (editmdctl абсолютизирует от cwd — как существующие команды). Если папка уже в workspaces — идемпотентный ok. + сабкоманда в editmdctl + тест-кейс в ControlChannelTests (по образцу существующих ping/unknown).
**Грабли:** прочитать `docs/HISTORY.md` § v38/v38.1 про control-канал ДО начала; диск не на main.
**Готово:** `editmdctl workspace add ~/notes` → папка появилась в сайдбаре; повторный вызов не дублирует; тесты зелёные.

### D7 · Демо-файл проверки разметки (S)
**Файлы:** новый ресурс `EditMD/EditMD/Resources/KitchenSink.md` (+ `project.yml`, если ресурсы перечислены явно — проверить; затем `xcodegen generate`), Help-меню в `EditMDApp.swift`.
**Сделать:** файл со ВСЕЙ поддерживаемой разметкой: заголовки 1–6, жирный/курсив/зачёркнутый/код, списки (в т.ч. task list, вложенные), цитаты (вложенные), fenced code (в т.ч. `yaml`), таблица, картинка, ссылки, wiki-link `[[Note|alias]]`, frontmatter, `---`. Пункт Help ▸ «Демо-разметка»: скопировать во временную папку (`FileManager.temporaryDirectory`) и открыть через существующий роутинг открытия (lite-окно).
**Готово:** пункт меню открывает документ, все три режима рендерят его без артефактов (заодно ручной smoke для C1–C4).

### D8 · Info корневой папки: все папки и подпапки (M-)
**Файлы:** `FolderInfoCard`/`FolderInfoHost` — `EditMD/EditMD/Views/WelcomeView.swift:162` и `FileEditor.swift:118`; данные — `WorkspaceModel.treeStats` (кэш).
**Сделать:** в карточку папки добавить секцию-дерево подпапок (имя + число .md), данные брать ТОЛЬКО из кэша `treeStats`/фонового скана WorkspaceModel (инвариант v35.3: никакого синхронного диска из body). Если текущий скан не даёт полной глубины — расширить фоновый скан, не карточку.
**Готово:** клик по корню workspace → карточка показывает вложенные папки с количеством файлов; открытие карточки не подвешивает UI на сетевом/большом каталоге.

### D9 · Редактор ссылок (M)
**Файлы:** `VisualCoordinatorFormat.swift` (⌘K уже вставляет ссылки, v23), `VisualTextView.swift` (клик/курсор на `md.link`).
**Сделать:** Visual: когда курсор внутри существующей ссылки, ⌘K (и пункт контекстного меню «Edit Link…») открывает тот же UI, что вставка, но с предзаполненными text/URL; Apply — заменить диапазон ссылки через restamp-паттерн. Source: v1 не трогать (маркеры видны, правится руками).
**Готово:** курсор в ссылку → ⌘K → правка URL → сериализация корректна `[text](url)`; undo одним шагом.

### D10 · Темы: главная + 5 (M-)
**Файлы:** `EditMD/EditMD/Editor/EditorTheme.swift` (пресеты system/comfortable/github), `SettingsView.swift` + `ContentView.swift` (меню 🎨).
**Сделать:** 5 новых пресетов (предложение: Sepia/книжная, Nord-подобная холодная, Solarized-подобная, High Contrast, Dracula-подобная тёмная) по образцу существующих: каждая обязана корректно жить в light И dark (динамические NSColor через provider — паттерн уже в кодовой базе, см. `dirtyMarkNSColor` в EditorSettings.swift:425). Поле `name` уникально (по нему сравнение тем — см. CLAUDE.md § updateNSView). Добавить в 🎨-меню и Settings.
**Готово:** каждая тема переключается на лету во всех трёх режимах, в обоих appearance читаема (руками прогнать D7-демо-файл).

### D11 · Вкладка «Теги» в сайдбаре (L — делать последней)
**Файлы:** новый `EditMD/EditMD/Views/TagsSidebar.swift`, `WorkspaceSidebar.swift` (пятая вкладка, по образцу Review), `WorkspaceModel.swift` (фоновый скан), `EditMD/EditMD/Editor/Frontmatter.swift` (`parseFrontmatterProperties` — уже парсит `tags`).
**Скоуп v1:** ТОЛЬКО frontmatter-теги (`tags: [a, b]` / block-list). Инлайн `#теги` — отдельно (конфликт с заголовками).
**Сделать:** 1) в WorkspaceModel фоновый скан frontmatter файлов workspace (строго по паттерну stale-while-revalidate, как `markdownFiles`/`treeStats`; читать только первые ~2КБ файла — frontmatter в начале). 2) `TagsSidebar`: список тегов с count → разворачивается в файлы → клик = `onOpen`. Фильтр через общий `filterText`. 3) Вкладка + иконка `tag` в navigatorToolbar.
**Грабли:** инвариант v35.3 (диск не в body); инвалидация кэша — по существующему механизму обновления скана.
**Готово:** теги из frontmatter всех workspace-файлов видны, клик открывает файл, большой каталог не вешает UI; тест на «скан тегов из frontmatter» в WorkspaceModelTests.

---

## Отложено — не брать без человека

| # | Пункт | Почему отложено |
|---|---|---|
| X1 | Плагины | Архитектурное решение (API, песочница, дистрибуция) — сначала research-док |
| X2 | Картинки | Скоуп не определён: drag&drop? remote async в Visual? (оба в «Осталось на будущее») |
| X3 | Тёмный/светлый режим | «Пофиксить» без репро — нужен конкретный сценарий от автора |
| X4 | Просмотр PDF | Роутинг не-markdown документов через DocumentRegistry — архитектурное решение |
| X5 | Подсветка кода в блоках | Выбор подхода: JS-highlighter в Preview vs нативно во всех трёх режимах (инвариант «три парс-пути») |
| X6 | Комментирование через тег + yaml | Открытый дизайн-вопрос («как визуально встроить») |
| X7 | Формулы | Скоуп: KaTeX только в Preview или все режимы; влияет на three-mode инвариант |
| X8 | Workspace: закреплять/спрашивать | Сам автор пометил «тема для размышления» |
| X9 | AI-вкладка в sidebar | Сначала дизайн (что показывать: статус, сессии, диффы, очередь?) |
| X10 | Visual: вставка markdown с форматированием | Пайплайн paste + round-trip — рискованная зона, для сильной модели с планом |
| X11 | Закладки-комментарии | Автор пометил «на подумать» |
| X12 | Таблицы: CRUD столбцов | NSTextTable + table-island (v29/v31) — самая хрупкая зона Visual |
| X13 | Tombstones review-меток | Требует согласования схемы sidecar со smotr (`~/Server/smotr`) — межпроектное решение |

## Рекомендуемый порядок

A (разогрев, низкий риск) → B (тулбар; B1 строго первым) → C (баги; C4 самый деликатный) → D по возрастанию размера (D1…D11). После каждого батча: полный прогон тестов + ручной smoke на демо-файле (появится в D7 — можно сделать D7 раньше, сразу после батча A, и использовать как тест-полигон).
