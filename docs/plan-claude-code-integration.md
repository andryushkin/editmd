# Инструкция по реализации: интеграция EditMD ↔ Claude Code

**Для кого:** исполнитель — Claude Opus в Claude Code, свежая сессия.
**Спецификация:** `docs/research/claude-code-integration.md` — читать ЦЕЛИКОМ до
первой строки кода. Там: протокольный референс IDE-канала (раздел 2), формат
меток smotr (1.2), маппинг на существующую архитектуру (4), риски (6).
Эта инструкция — операционный план поверх той спеки; при противоречии
спека главнее, но противоречие сначала показать пользователю.

---

## 0. Перед стартом (обязательный чеклист)

1. Прочитать `CLAUDE.md` полностью — инварианты проекта нарушать нельзя.
2. Прочитать `docs/research/claude-code-integration.md` полностью.
3. Прочитать в `docs/HISTORY.md` разделы **v34** (external changes, diff,
   knownModDate) и **v35** (git-сайдбар, off-main правила) — фаза 1 стоит
   на их механике.
4. Посмотреть живьём: `DocumentStore.swift` (DocumentRegistry),
   `WorkspaceModel.swift`, `AppState.swift`, `TextDiff.swift`,
   `ExternalChangeUI.swift`, `MarkdownLint.swift` — это точки интеграции.

## 1. Жёсткие рамки (нарушение = стоп и вопрос пользователю)

- **Никакого встроенного чата** и никаких обращений к Anthropic API из
  приложения. EditMD не хранит ключей. Claude работает в терминале
  пользователя по его подписке.
- **Правки Claude попадают в документ только через diff-подтверждение**
  (Accept/Reject). Никакой прямой записи в файлы из tool-хендлеров.
- **Accept пишет через DocumentRegistry / общий flush**, который обновляет
  `knownModDate` и re-arm'ит watch (инвариант v34). Запись мимо реестра =
  собственная правка прикинется external change. Это баг-ловушка №1.
- **Swift 6 strict concurrency соблюдать, а не глушить**: сетевой код вне
  main actor; в UI — через `@MainActor`-фасад. `nonisolated(unsafe)` — только
  по образцу уже существующих мест, с комментарием почему безопасно.
- **Не трогать** attributed-модель Visual, сериализатор round-trip, пороги
  больших файлов. Интеграция — слой СБОКУ от редактора, не внутри него.
- **В SwiftUI body — никакого диска/Process/сети** (инвариант v35.3).
- **`project.yml` — единственный источник структуры**: новые файлы → правка
  project.yml → `xcodegen generate`.
- Одна фаза = одна ветка + один минорный номер версии. Между фазами —
  чекпоинт с пользователем, следующую фазу без его «поехали» не начинать.

## 2. Сборка и ворота качества (после каждого шага)

```bash
cd EditMD
xcodegen generate   # если менялся project.yml
xcodebuild -scheme EditMD -destination "platform=macOS" build
xcodebuild -scheme EditMD -destination "platform=macOS" -enableCodeCoverage NO test
```

- `-enableCodeCoverage NO` обязателен (linker error без него).
- Красный тест — чинить сразу, не накапливать.
- Визуальная верификация: screencapture в этом окружении недоступен —
  собрать, запустить app и попросить пользователя посмотреть глазами,
  перечислив что именно проверять.
- По завершении фазы: обновить `CLAUDE.md` (краткая карта + инварианты, если
  появились новые) и `docs/HISTORY.md` (раздел новой версии с gotchas).

---

## 3. Фаза 1 — IDE/MCP-сервер (v36)

**Результат фазы:** пользователь открывает workspace в EditMD, в терминале
`cd <workspace> && claude`, командует `/ide` → Claude видит текущий файл,
выделение, workspace; «перепиши выделенное» → в EditMD открывается diff →
Accept применяет, Reject отклоняет, Claude получает `FILE_SAVED` /
`DIFF_REJECTED`.

Новая папка `EditMD/EditMD/Integration/`. Разбивка по шагам — каждый шаг
компилируется и покрыт тестами до перехода к следующему.

### Шаг 1.1 — MCP-ядро и WS-сервер

Файлы: `MCPProtocol.swift` (JSON-RPC 2.0 кодек: request/response/notification,
ошибки), `ClaudeIDEServer.swift` (NWListener + `NWProtocolWebSocket.Options`,
bind строго `127.0.0.1`, ephemeral-порт; отклонять апгрейд без валидного
header `x-claude-code-ide-authorization`).

- Сервер — actor или класс с собственной очередью; никакого main actor.
- Handshake: `initialize` (protocolVersion из спеки, раздел 2.2) →
  `tools/list` → `tools/call` роутинг.
- Тесты: кодек JSON-RPC (запрос/ответ/ошибка/notification), auth-отказ.

### Шаг 1.2 — lock-файл

Файл: `IDELockFile.swift`. JSON-схема — спека 2.1, дословно:
`pid, workspaceFolders, ideName:"EditMD", transport:"ws", authToken`.

- `authToken`: 16 байт `SecRandomCopyBytes` → 32 hex lowercase.
- Права: файл 0600, каталог `~/.claude/ide/` 0700.
- Жизненный цикл: писать при старте сервера, удалять при остановке/выходе
  app; при старте вычищать stale-файлы с мёртвым pid.
- `workspaceFolders` = корни `WorkspaceModel`; при добавлении/удалении папки
  перезаписывать lock-файл (риск 6.4 спеки — проверить руками, что живое
  подключение это переживает; результат записать в HISTORY).
- Тесты: запись/чтение/права/stale-cleanup (через временный HOME или
  инжектированный путь).

### Шаг 1.3 — 12 стандартных tools

Файл: `ClaudeIDETools.swift`. Таблица имён/параметров/ответов — спека 2.4,
следовать ей дословно (включая snake_case у `close_tab` и JSON-строку внутри
`content[0].text`). Маппинг:

- `getCurrentSelection` / `getLatestSelection` — из Coordinator'ов
  Source/Visual через main-actor фасад (см. шаг 1.5 про координаты Visual).
- `getOpenEditors` — снимок DocumentRegistry (`isDirty` из модели).
- `getWorkspaceFolders` — WorkspaceModel.
- `openFile` — роутинг через AppState (как открытие из сайдбара);
  `startText`/`endText` — поиск по строке, выделение найденного диапазона.
- `checkDocumentDirty` / `saveDocument` — DocumentRegistry.
- `getDiagnostics` — прогнать `lint()` по содержимому файла, замапить в
  LSP-подобный формат из спеки (`source: "editmd-lint"`, severity по типу
  правила). Наше преимущество, не отдавать `[]`.
- `close_tab` / `closeAllDiffTabs` — только diff-вью Claude (шаг 1.4).
- `executeCode` — мягкий отказ (`success:false`, понятный message).
- `openDiff` — шаг 1.4.
- Тесты: каждый tool против фейковых реестра/workspace (формат ответа,
  edge-кейсы: нет выделения, файл не открыт, файл вне workspace).

### Шаг 1.4 — openDiff UI (сердце фазы)

Файлы: `DiffApprovalController.swift` + вью в `Views/` (переиспользовать
рендер unified diff v34).

- Blocking-семантика: tool-хендлер подвешивается на continuation; UI
  показывает sheet «Claude предлагает изменение: <tab_name>» с diff
  old↔`new_file_contents` и кнопками Принять/Отклонить.
- Принять → запись через DocumentRegistry (рамка №1!) → ответ `FILE_SAVED`.
  Отклонить → `DIFF_REJECTED`. Закрытие окна/sheet без выбора = Reject.
- Continuation обязан разрешиться ровно один раз: disconnect клиента,
  таймаут (например 10 мин), повторный `openDiff` по тому же файлу —
  все пути ведут к `DIFF_REJECTED`, утечка continuation недопустима.
- Если файл открыт и dirty — diff строить против буфера, предупредить в UI.
- Тесты: continuation-семантика (accept/reject/disconnect/двойной ответ)
  без UI, через контроллер.

### Шаг 1.5 — notifications

- `selection_changed`: из `textViewDidChangeSelection` обоих режимов,
  debounce ≥200 мс, пустые выделения не слать. Формат — спека 2.3.
- **Visual → source координаты:** line/character считаются по
  markdown-строке (source of truth), не по attributed-тексту. Использовать
  существующий маппинг курсора между режимами (v22). Если точный маппинг
  внутри строки нехрупко не получается — слать начало соответствующей
  source-строки и зафиксировать ограничение в HISTORY, не изобретать
  сложный костыль.
- `at_mentioned`: пункт контекстного меню и Format/Edit-команда
  «Send to Claude» (`filePath, lineStart, lineEnd`); пункт активен только
  при живом подключении.

### Шаг 1.6 — обвязка

- Settings ▸ General: тумблер «Claude Code integration» (default on) —
  включает/выключает сервер + lock-файл.
- Индикатор подключения: чип в тулбаре по образцу git/external-change чипов
  v34–v35 (серый = сервер слушает, цветной = клиент подключён; tooltip с
  портом).
- Логирование: `os.Logger`, категория `claude-ide`; при disconnect/ошибках
  протокола — лог, не алерты.

### Шаг 1.7 — интеграционный smoke + ручная приёмка

- **Скриптовый WS-клиент** (Python, стандартная библиотека или swift-скрипт,
  положить в `EditMD/scripts/ide-smoke/`): читает lock-файл → connect с
  auth-header → `initialize` → `tools/list` → `getCurrentSelection` →
  `openDiff` → программный Reject недоступен, поэтому smoke проверяет
  доставку запроса, а решение кликает человек; остальные tools — assert
  формата ответов. Это страховка от изменений протокола (риск 6.1 спеки).
- **Ручная приёмка с реальным CLI** — выдать пользователю чеклист:
  1. EditMD с workspace-папкой; `claude` в этой папке; `/ide` — подключение
     видно чипом.
  2. Выделить абзац → в Claude «what am I looking at» → он цитирует
     выделение.
  3. «перепиши этот абзац короче» → diff в EditMD → Accept → текст
     обновился, conflict-чип НЕ появился (инвариант v34 соблюдён).
  4. То же с Reject → файл не тронут, Claude сообщил об отказе.
  5. Файл с линт-проблемами → «fix lint issues in this file» → Claude видит
     диагностику и предлагает diff.
  6. Два окна/несколько workspace-папок → `/ide` из второй папки.

**За пределами фазы 1** (не делать, даже если «просто»): кастомные
EditMD-tools (фаза 1.5 спеки — отдельное решение из-за фильтрации
`tools/list`), lite-окна как активный редактор, embedded-терминал.

---

## 4. Фаза 2 — метки-треды smotr-style (v37)

Начинать только после приёмки фазы 1 пользователем.

**Результат:** выделение в EditMD → метка-тред (`question/fix/rewrite/cut/
keep/comment`) в sidecar `<file>.md.review.json` **в формате smotr** (спека
1.2; сам формат смотреть в `~/Server/smotr/README.md` и `serve.py` — схема
`{rev, marks:[{id,type,quote,prefix,note,status,thread,…}]}`); вкладка
**Review** в сайдбаре; suggest-метки → карточка «было → станет» с ✓/✕.

Ключевые требования:

- **Совместимость со smotr — контрактная**: sidecar, записанный EditMD,
  открывается smotr-вью без потерь, и наоборот. Обязателен round-trip тест
  EditMD ↔ фикстуры реального smotr-sidecar. Схему не расширять без
  согласования с пользователем (движок smotr общий на все проекты).
- `rev`-конкуренция: перед записью перечитать файл; чужой rev выше → merge
  по `id`, не затирать.
- Якоря `quote + prefix`: перепривязка при изменении текста; фрагмент
  исчез → статус `needs-rebase`, не «примерно туда».
- Применение suggest — та же машинерия Accept, что openDiff (через реестр).
- Запуск обработки: кнопка ➤ в Review-вкладке собирает очередь
  (`.smotr-queue.json`, как smotr) и показывает команду для терминала;
  opt-in тумблер «запускать Claude автоматически» → `Process` со
  `claude -p "/smotr -pr"` в корне workspace, прогресс из
  `--output-format stream-json`, лог в файл. Spawn — вне main actor.
- Track-changes-рендер внутри Visual-текста в фазу НЕ входит (только
  карточки в панели) — вмешательство в attributed-модель запрещено рамками.

## 5. Фаза 3 — editmdctl + skill (v38)

Начинать только после приёмки фазы 2.

**Результат:** CLI `editmdctl` управляет редактором через unix-socket;
skill `~/.claude/skills/editmd/` учит Claude командам; установка из
«Help ▸ Install Agent Skill…» (паттерн agterm, спека 1.1).

- Socket: `~/Library/Application Support/EditMD/control.sock`, JSON-lines
  (запрос-строка → ответ-строка); переиспользовать роутинг команд из MCP-ядра
  фазы 1 — один слой «команды редактора», два транспорта.
- Команды минимум: `open <path> [--heading H | --line N]`, `reveal`,
  `mode source|visual|preview`, `marks list|add`, `status`, `diff show`.
- `editmdctl` — отдельный CLI-таргет в project.yml; вывод — JSON при
  `--json`, человекочитаемый по умолчанию.
- Skill: markdown-инструкция с командами + workflow меток фазы 2; installer
  копирует в `~/.claude/skills/editmd/` с подтверждением и показывает diff
  при обновлении существующего.
- Тесты: socket round-trip (поднять сервер в тест-хосте, прогнать команды),
  идемпотентность installer.

## 6. Правила поведения при неожиданностях

- **Живой CLI расходится с PROTOCOL.md** → доверять живому CLI: логировать
  весь трафик (toggle в Settings ▸ Advanced или env-флаг), задокументировать
  расхождение в HISTORY, спеку поправить.
- **Зависание/фриз** → `sample <pid> 3`, не догадки (инвариант CLAUDE.md).
- Не получается уложиться в рамки раздела 1 → остановиться и спросить
  пользователя, а не ослаблять рамку.
- Флейки `xcodebuild test`: codesign stale bundle → wipe Build; TCC-ханг
  тест-хоста → sample процесса.
