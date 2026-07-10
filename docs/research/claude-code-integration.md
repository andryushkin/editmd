# Research: интеграция EditMD ↔ Claude Code

**Статус:** research, кода нет. Решения зафиксированы 2026-07-10.

**Цель:** EditMD взаимодействует с Claude Code для markdown-задач: правка
выделенного, ревью-петля документа, задачи по workspace (суммаризация,
wiki-links, структура), механика (линт-фиксы, таблицы, frontmatter).

**Принятые решения (сессия 2026-07-10):**

- Три канала, фазируются: **IDE/MCP-сервер** (фаза 1) → **метки-треды
  smotr-style** (фаза 2) → **editmdctl + socket agterm-style** (фаза 3).
  Встроенный чат в EditMD — сознательно НЕ делаем (не выбран).
- Правки Claude попадают в документ **только через diff-подтверждение**
  (Accept/Reject в EditMD), не прямой записью в файл.
- Claude Code работает по подписке пользователя, из его терминала —
  EditMD не хранит API-ключей и не ходит в Anthropic API сам.

---

## 1. Прецеденты: три модели взаимодействия «приложение ↔ агент»

### 1.1 agterm — «приложение как управляемая среда»

[agterm](https://github.com/umputun/agterm) (umputun) — macOS-терминал для
AI-агентов (рендер libghostty, UI SwiftUI/AppKit). Claude Code живёт *внутри*
терминала обычным процессом; agterm не встраивает агента через API, а даёт
агенту ручки для управления самим приложением. Четыре слоя:

1. **Unix-domain socket + CLI `agtermctl`** — весь контроль приложения:
   сессии (create/rename/close), инжекция текста как нажатий клавиш
   (`session type`), overlay-программы поверх сессии
   (`session overlay open lazygit`), поиск/навигация, уведомления, статусы.
2. **Env-инъекция** — в каждую сессию прокидываются `AGTERM_ENABLED`,
   `AGTERM_SESSION_ID`, `AGTERM_WORKSPACE_ID`, `AGTERM_SOCKET`, `AGTERM_PANE`:
   агент самоидентифицируется без хардкода ID.
3. **Agent Skill** — «Help ▸ Install Agent Skill…» кладёт skill в
   `~/.claude/skills/agterm/` (и `~/.codex/skills/agterm/`), который учит
   агента всему набору `agtermctl`. Агент управляет терминалом без объяснений.
4. **Status hooks** — установщик вшивает hooks в `~/.claude/settings.json`:
   события Claude Code мапятся на статус сессии в сайдбаре
   (prompt → `active`, Stop → `completed --auto-reset`, permission prompt →
   `blocked`); attention-list и авто-фокус на заблокированные сессии.

**Вывод для EditMD:** паттерн «socket + ctl-CLI + skill + hooks» — это фаза 3
(editmdctl). Отдельно ценна идея installer-пунктов в Help-меню и статусов
агента как UI-чипа.

### 1.2 smotr — «файловая ревью-петля»

[smotr](file:///Users/andryushkin/Server/smotr) (локальный, `~/Server/smotr`) —
review-движок: веб-вью для разметки артефактов, канал автор → Клод. Ключевые
механики (детали — README smotr):

- **Sidecar-метки**: `<file>.md.review.json` рядом с файлом, оригинал не
  трогается, трекается в git. Формат:
  `{rev, marks: [{id, type, quote, prefix, note, status, thread, …}], prompts}`.
- **Метка = тред с жизненным циклом**: тип-намерение
  (`question / fix / rewrite / cut / keep / comment`), статус
  (`open / resolved / wontfix / needs-info / needs-rebase`), диалог на якоре.
  Клод обрабатывает по приоритету question → fix → rewrite → cut, отвечает
  в тред и ставит статус.
- **Suggestions (track-changes)**: Клод НЕ пишет в файл — кладёт
  `suggest`-метку (`quote` → `replacement` + rationale); движок рендерит как
  track-changes и применяет по кнопке ✓ Принять (с перепривязкой якоря по
  `quote` + `prefix`; фрагмент уехал → честный `needs-rebase`).
- **Очередь + агент**: кнопка ➤ собирает открытые метки в `.smotr-queue.json`;
  с флагом `--agent` движок сам вызывает `claude -p "/smotr -pr"` в корне
  проекта (headless), лог в `.smotr-agent.log`.
- **Конкурентная запись**: счётчик `rev` в sidecar; устаревший rev при POST →
  409, фронт мержит по `id` и повторяет. Клод читает метки через
  `GET /api/marks?status=open` или напрямую из файлов.

**Вывод для EditMD:** формат sidecar-меток и жизненный цикл треда уже
спроектированы и обкатаны — фаза 2 должна переиспользовать формат smotr,
а не изобретать свой (EditMD становится вторым фронтендом тех же меток).
Suggest-механика = наш «diff на подтверждение» в асинхронном варианте.

### 1.3 Obsidian-плагины — «приложение как IDE для Claude Code»

Два плагина реализуют **IDE-протокол Claude Code** — тот же WebSocket/MCP
контракт, что у официальных расширений VS Code/JetBrains:

- [obsidian-claude-code-mcp](https://github.com/iansinnott/obsidian-claude-code-mcp)
  (iansinnott) — WS для Claude Code + HTTP/SSE для Claude Desktop.
- [obsidian-claude-code-ide-pro](https://github.com/transept-ai/obsidian-claude-code-ide-pro)
  (Transept) — полная реализация: 12 стандартных IDE-tools + 8 vault-специфичных
  (getBacklinks, resolveWikilink, searchVault, getFrontmatter, …), diff через
  CodeMirror MergeView с Accept/Reject.

Claude Code в терминале сам находит редактор (lock-файл), видит текущую
заметку/выделение, а diff предлагаемой правки открывается в приложении.
Это фаза 1. Протокол — раздел 2.

---

## 2. IDE-протокол Claude Code — технический референс

Протокол не задокументирован Anthropic публично; референс собран из
реверс-инженерных реализаций (самая полная —
[claudecode.nvim/PROTOCOL.md](https://github.com/coder/claudecode.nvim/blob/main/PROTOCOL.md)),
сверено с обоими Obsidian-плагинами. Это **риск**: контракт может измениться
с релизом CLI (см. раздел 6).

### 2.1 Discovery: lock-файл

IDE поднимает WebSocket-сервер на `127.0.0.1` (ephemeral-порт 10000–65535)
и пишет `~/.claude/ide/<port>.lock` (права 0600, каталог 0700):

```json
{
  "pid": 12345,
  "workspaceFolders": ["/path/to/project"],
  "ideName": "EditMD",
  "transport": "ws",
  "authToken": "a3f1c2d4e5f60718293a4b5c6d7e8f90"
}
```

`authToken` — 32 hex-символа из CSPRNG (`SecRandomCopyBytes`), новый на каждый
запуск; живёт только в памяти и lock-файле. Файл удаляется при выключении;
при старте чистить stale-файлы по мёртвому `pid`.

**Как подключается Claude Code:**

- Из терминала, встроенного в IDE: IDE ставит env `CLAUDE_CODE_SSE_PORT` и
  `ENABLE_IDE_INTEGRATION=true` — авто-подключение. *(Не наш случай — EditMD
  не терминал.)*
- Из внешнего терминала: команда `/ide` — CLI сканирует `~/.claude/ide/*.lock`,
  матчит lock-файл, чей `workspaceFolders` накрывает текущий cwd, читает порт
  и токен, подключается. **Это наш основной сценарий**: пользователь запускает
  `claude` в папке workspace и делает `/ide`.

### 2.2 Транспорт и auth

JSON-RPC 2.0 поверх WebSocket (MCP-спецификация 2025-03-26, адаптированная
под WS-транспорт). Каждое подключение обязано нести header
`x-claude-code-ide-authorization: <authToken>`; мисматч → 401. Сервер строго
на loopback. Стандартный MCP-handshake: `initialize` → `tools/list` →
`tools/call`.

### 2.3 Notifications IDE → Claude

**`selection_changed`** — при смене выделения (слать с debounce, фильтровать
пустые):

```json
{"jsonrpc":"2.0","method":"selection_changed","params":{
  "text":"выделенный текст","filePath":"/abs/path/file.md",
  "fileUrl":"file:///abs/path/file.md",
  "selection":{"start":{"line":10,"character":5},
               "end":{"line":15,"character":20},"isEmpty":false}}}
```

**`at_mentioned`** — пользователь явно отправил фрагмент в контекст Claude
(«Send to Claude»):

```json
{"jsonrpc":"2.0","method":"at_mentioned","params":{
  "filePath":"/abs/path/file.md","lineStart":10,"lineEnd":20}}
```

### 2.4 Tools Claude → IDE (12 стандартных)

| Tool | Вход | Поведение / выход |
|---|---|---|
| `getCurrentSelection` | — | Текущее выделение активного редактора: `{success, text, filePath, selection}` |
| `getLatestSelection` | — | Последнее непустое выделение (кэш) |
| `getOpenEditors` | — | `{tabs:[{uri, isActive, label, languageId, isDirty}]}` |
| `getWorkspaceFolders` | — | `{success, folders:[{name, uri, path}], rootPath}` |
| `openFile` | `{filePath, preview?, startText?, endText?, selectToEndOfLine?, makeFrontmost?}` | Открыть файл, опционально выделить диапазон по тексту |
| `openDiff` | `{old_file_path, new_file_path, new_file_contents, tab_name}` | **Единственный BLOCKING tool** — ждёт решения пользователя; ответ `FILE_SAVED` (принял) или `DIFF_REJECTED` (отклонил) |
| `checkDocumentDirty` | `{filePath}` | `{success, filePath, isDirty, isUntitled}` |
| `saveDocument` | `{filePath}` | Сохранить файл |
| `close_tab` | `{tab_name}` | Закрыть вкладку (внимание: snake_case) → `TAB_CLOSED` |
| `closeAllDiffTabs` | — | Закрыть все diff-вью Claude → `CLOSED_N_DIFF_TABS` |
| `getDiagnostics` | `{uri?}` | LSP-диагностика; Obsidian возвращает `[]` — **у нас есть линтер** (см. 4.2) |
| `executeCode` | `{code}` | Jupyter-only; мягкий отказ |

Все ответы — MCP-массивы `{"content":[{"type":"text","text":"…"}]}`, полезная
нагрузка — JSON-строкой внутри `text`. Имена camelCase, кроме `close_tab`.

**Семантика `openDiff` — сердце «diff на подтверждение»:** Claude вызывает
tool и блокируется; IDE показывает diff old↔new с кнопками; «Принять» = IDE
сама записывает `new_file_contents` и отвечает `FILE_SAVED`, «Отклонить» =
`DIFF_REJECTED`, Claude продолжает с учётом ответа.

---

## 3. Headless-режим Claude Code (двигатель фазы 2)

Для асинхронной обработки меток (кнопка «обработать» в EditMD, как
`--agent` у smotr):

- `claude -p "<prompt или /skill>"` — одноразовый headless-запуск в cwd
  проекта; работает по подписке пользователя, разрешения — по его
  `settings.json`.
- `--output-format stream-json` — машиночитаемый стрим событий (для
  прогресс-индикатора «⏳ Клод обрабатывает…»).
- Skill в `~/.claude/skills/` задаёт workflow обработки (читать метки →
  отвечать в тред → класть suggest) — smotr это уже делает через `/smotr -pr`.

EditMD-у достаточно `Process` + чтение stdout; не нужен ни SDK, ни API-ключ.

---

## 4. Проекция на EditMD: что уже есть

| Нужно для интеграции | Уже в EditMD |
|---|---|
| Список workspace-папок | `WorkspaceModel` (несколько корней) |
| Открытые файлы + dirty | `DocumentRegistry` (модель на URL, refcount, autosave) |
| Открыть файл / перейти | `AppState.currentURL` + роутинг v28 |
| Выделение/курсор | Coordinator’ы Source/Visual (`textViewDidChangeSelection`) |
| Diff-вью | v34: unified diff (`TextDiff.swift`) + External-change UI |
| Диагностика | `MarkdownLint` — 14 правил + quick-fix (наш `getDiagnostics`!) |
| Outline, wiki-links, frontmatter | `MarkdownOutline`, `WikiLinkResolver`, `Frontmatter.swift` |
| Реакция на внешнюю запись | v34 watch + auto-reload/conflict |

Sandbox отсутствует (нет `.entitlements` в `project.yml`) — локальный
WS-сервер и unix-сокет не требуют entitlements.

### 4.1 Критичный инвариант при Accept в openDiff

Принятие diff = **своя** запись файла: идти через `DocumentRegistry`/наш flush,
который обновляет `knownModDate` и re-arm’ит watch (инвариант v34) — иначе
собственная запись сработает как external change и вылезет conflict-чип.

### 4.2 getDiagnostics — наше преимущество

Obsidian отдаёт `[]`; EditMD может отдавать линт (14 правил) в формате
LSP-подобной диагностики (`message, severity, range, source:"editmd-lint"`).
Claude тогда сам видит проблемы файла и чинит их через `openDiff` — задача
«механика: линт» закрывается почти бесплатно.

---

## 5. Фазы

### Фаза 1 — IDE/MCP-сервер (основная)

**Сценарий:** пользователь работает в EditMD, рядом терминал с `claude`;
`/ide` → Claude видит текущий документ/выделение/workspace; «перепиши
выделенное» → `openDiff` в EditMD → Accept/Reject.

Состав:

1. **WS-сервер**: `Network.framework` (`NWListener` +
   `NWProtocolWebSocket`) — server-side WS из стандартного SDK, без
   зависимостей; loopback, ephemeral-порт, проверка auth-header. Альтернатива
   SwiftNIO — не нужна на этих объёмах. Вся работа вне main actor, мосты в UI
   через `@MainActor`-фасад.
2. **Lock-файл менеджер**: запись при старте (или при первом открытии
   workspace), `workspaceFolders` = корни `WorkspaceModel` (+ папка текущего
   файла для lite-окон?), удаление при выходе, чистка stale по pid.
3. **MCP-ядро**: JSON-RPC 2.0, `initialize`/`tools/list`/`tools/call`,
   12 tools из 2.4. `getOpenEditors` = снимок `DocumentRegistry`;
   `openFile` = роутинг через `AppState`; `getDiagnostics` = линтер.
4. **openDiff UI**: sheet/split с diff (переиспользовать v34-рендер) + кнопки
   «Принять»/«Отклонить»; принятие пишет `new_file_contents` через реестр
   (4.1). Ответ tool-у — после действия пользователя (continuation, timeout
   на случай закрытия окна).
5. **Notifications**: `selection_changed` с debounce из Coordinator’ов;
   `at_mentioned` — пункт контекстного меню/команда «Send to Claude»
   (работает только при подключённом клиенте).

**Фаза 1.5 (после стабилизации):** EditMD-специфичные tools по образцу
ide-pro: `getOutline`, `resolveWikilink`, `searchWorkspace`, `getFrontmatter`,
`applyLintFix`. Осторожно: ide-pro отмечает, что кастомные tools советуется
фильтровать из `tools/list` IDE-канала (CLI ожидает фиксированный набор) и
отдавать через параллельный stdio MCP-сервер (`claude mcp add`).

**Мульти-окна:** «active editor» фазы 1 = главное workspace-окно; lite-окна
(`WindowGroup(for: URL)`) участвуют в `getOpenEditors`, но выделение/diff —
в главном. Расширение на lite-окна — отдельным шагом.

### Фаза 2 — метки-треды (smotr-совместимые)

**Сценарий:** выделил текст в EditMD → метка `question/fix/rewrite/…` в
sidecar `<file>.md.review.json` (формат smotr, раздел 1.2) → кнопка
«обработать» спавнит `claude -p` (или пользователь запускает сам) → ответы
в тредах, suggest-правки → Accept/Reject в EditMD.

- **Формат — smotr as-is** (rev-конкуренция, quote+prefix якоря, статусы):
  EditMD = второй фронтенд тех же меток; существующий skill-workflow
  переиспользуется, разметку можно начинать в smotr-вью и триажить в EditMD.
- UI: новая вкладка сайдбара **Review** (рядом с Files/Outline/Git): список
  тредов, фильтры по типу/статусу, реплай; в тексте — подсветка якорей
  (атрибут поверх, как линт; в Visual — по plainText-поиску quote).
- Suggest = тот же «diff на подтверждение», но асинхронный: карточка
  «было → станет» + ✓/✕; применение — через реестр, с перепривязкой якоря
  и честным `needs-rebase`.
- Track-changes-рендер в Visual (зачёркнутый оригинал + замена рядом) —
  вторым шагом, это вмешательство в attributed-модель.

### Фаза 3 — editmdctl (agterm-style)

**Сценарий:** Claude из любого терминала командует редактором: «открой
файл X на заголовке Y», «покажи diff», «поставь метку».

- Unix-domain socket (`~/Library/Application Support/EditMD/control.sock`),
  JSON-lines протокол; тонкий CLI `editmdctl` (мини-бинарь или swift-скрипт).
- Команды-минимум: `open <path> [--heading H|--line N]`, `reveal`,
  `mode source|visual|preview`, `marks list/add`, `status`.
- **Skill** `~/.claude/skills/editmd/` — учит Claude командам + workflow
  меток; установка из «Help ▸ Install Agent Skill…» (паттерн agterm).
- Опционально hooks-статусы: чип «Claude working/blocked/done» в тулбаре
  (паттерн agterm status hooks, у нас уже есть место чипов v34).

Фазы дополняют друг друга: MCP-канал живёт только пока подключён `/ide`;
editmdctl работает всегда (в т.ч. для скриптов без Claude); метки — единственный
канал, переживающий перезапуски обоих.

---

## 6. Риски и открытые вопросы

1. **IDE-протокол — реверс, не публичный контракт.** Может измениться с
   релизом CLI. Митигция: интеграционный smoke-тест — скриптовый WS-клиент,
   имитирующий handshake CLI (ловим поломку у себя); следить за
   claudecode.nvim/PROTOCOL.md и ide-pro как за «каноном» изменений.
2. **`openDiff` blocking + Swift 6 concurrency** — ответ tool-а ждёт действия
   пользователя: continuation, хранимый вне main actor, timeout/отмена при
   закрытии окна и disconnect клиента.
3. **Матчинг cwd → workspaceFolders** при `/ide`: пользователь должен
   запускать `claude` внутри одного из корней workspace; несколько окон
   EditMD = несколько lock-файлов — поведение CLI при неоднозначности
   проверить руками.
4. **`workspaceFolders` динамичен** (папки добавляются/убираются) — нужно ли
   переписывать lock-файл на лету и переживает ли это подключённый клиент.
5. **Куда шлётся `selection_changed` в Visual** — координаты line/character
   считаются по markdown-сериализации, не по attributed-тексту; нужен маппинг
   позиции Visual → source-строка (задел: курсор/скролл уже мапится между
   режимами с v22).
6. **Формат smotr эволюционирует** (движок общий) — фиксировать совместимую
   подмножество-схему меток и гонять round-trip тест sidecar EditMD ↔ smotr.

## 7. Источники

- agterm — README: https://github.com/umputun/agterm
- smotr — `~/Server/smotr/README.md` (формат меток, suggestions, `--agent`)
- Протокол IDE: https://github.com/coder/claudecode.nvim/blob/main/PROTOCOL.md
- Obsidian-реализации: https://github.com/iansinnott/obsidian-claude-code-mcp ,
  https://github.com/transept-ai/obsidian-claude-code-ide-pro
