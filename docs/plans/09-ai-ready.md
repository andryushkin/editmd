# План 09 — «AI ready»: единая система интеграции агентов + UX

Статус: не начат
Зависимости: нет (Review-цикл и control socket уже на main)
Разблокирует: маркетинговое «AI ready», работу с Codex/pi/другими харнесами

## Цель

Свести четыре существующие AI-поверхности (Review-цикл, Claude IDE bridge,
control socket/editmdctl, skill installer) в одну систему с одним видимым
лицом в UI и слоистой совместимостью с любым харнесом:

- **Слой 0 — файлы**: sidecar `.review.json` + `.smotr-queue.json` (уже есть).
- **Слой 1 — CLI**: control socket + `editmdctl` (уже есть, не задокументирован для агентов).
- **Слой 2 — skill-пакет**: документация, которую видит агент (новое).
- **Слой 3 — адаптеры харнесов**: hooks/extensions + MCP stdio proxy (новое).

Образец архитектуры — agterm (`/Applications/agterm.app/Contents/Resources/`):
control socket + CLI как единственный канал, skill-пакет в бандле с установкой
в `~/.claude/skills/` **и** `~/.codex/skills/`, универсальный status-враппер
(no-op вне контекста, всегда exit 0) + тонкие адаптеры под Claude Code / Codex /
pi / shell. Примечательно: agterm обходится **без MCP** — у нас MCP остаётся
только для того, что CLI не умеет (блокирующий `openDiff`, pull выделения).

## Контекст и существующий код

Прочитай перед началом: `CLAUDE.md` (разделы «Preview, review и integration»,
«Локализация»), `docs/HISTORY.md` (разделы про Claude-интеграцию и review).

- `EditMD/EditMD/Integration/ClaudeIDEBridge.swift` — состояние подключения
  Claude Code (WebSocket/MCP, lock-файл), selection context.
- `EditMD/EditMD/Integration/DiffApprovalController.swift` — блокирующий
  `openDiff` (continuation ровно один раз: Accept/Reject/close/disconnect/timeout).
- `EditMD/EditMD/Integration/ControlServer.swift` / `ControlRouter.swift` /
  `ControlProtocol.swift` — control socket; router двухфазный (main state +
  deferred disk work), socket-клиенты не блокируют main.
- `EditMD/EditMD/Integration/SkillInstaller.swift` — установка `/smotr` skill;
  база для обобщения.
- `EditMD/EditMD/Integration/MCPProtocol.swift` — формат MCP-сообщений, база
  для stdio-прокси.
- `EditMD/EditMD/Editor/ReviewQueue.swift` + `ReviewAgentRunner` — кнопка ✈️:
  очередь + спавн `claude -p "/smotr -pr"` (env-переопределение `EDITMD_AGENT_CMD`).
- `EditMD/EditMD/Views/ReviewSidebar.swift` / `ReviewModel.swift` — сайдбар
  ревью, статус-баннер `queueStatus`.
- `EditMD/EditMD/Views/ExternalChangeUI.swift` — текущая обработка внешних
  изменений файла.
- `EditMD/EditMD/Views/SettingsView.swift` — куда добавляется вкладка Integrations.
- `EditMD/project.yml` — новые targets/resources; после правок xcodegen.

## Принцип UX: каждый AI-touchpoint ведёт дальше

Пользователь не обязан знать возможности заранее — интерфейс подсказывает
следующий шаг в момент действия. Ни одно AI-состояние не является тупиком:

- **Поставил метку** → появляется подсказка следующего шага: «1 open mark —
  send to Claude ✈️» (ненавязчиво, в том же сайдбаре; исчезает после отправки).
- **Кликнул ✨, а агент не подключён** → popover не «пусто/серо», а список
  конкретных действий из текущего контекста: отправить метки (✈️), установить
  skill/CLI, скопировать готовый промпт.
- **Готовые промпты, которые точно сработают**: короткая контекстная
  «палитра промптов» в popover ✨ — команды, собранные из текущего состояния
  (активный файл, число открытых меток, workspace root), одна кнопка Copy:
  - есть открытые метки → `claude -p "/smotr -pr"` (или команда выбранного
    в Integrations харнеса);
  - меток нет → «попроси агента отревьюить файл»: готовая команда с путём
    активного файла и инструкцией оставить метки через editmdctl;
  - агент в терминале уже работает → сниппет «подключи EditMD»: строка,
    которую можно вставить агенту (прочитай skill / используй editmdctl).
  Промпты берутся из тех же шаблонов, что и skill-пакет (Этап 3), чтобы
  никогда не расходиться с реально работающими командами.
- **Пустые состояния учат**: Review-таб без меток показывает цикл из трёх
  шагов; Integrations без установок показывает «с чего начать».

Каждый этап ниже обязан проверяться этим принципом: после действия
пользователя видно, что произошло и что можно сделать дальше.

Инварианты, которые нельзя нарушить:

- Правки агента — только через `DocumentRegistry.applyAgentEdit`.
- IDE/control services не запускаются под XCTest.
- Протокольные сообщения/логи не локализуются; все user-facing строки —
  английские литералы + ru-перевод в `Localizable.xcstrings`.
- `openDiff` continuation завершается ровно один раз.

## Этап 1 — AgentActivityModel + индикатор в тулбаре (лицо системы)

Единый источник правды о присутствии/активности агента и один видимый
элемент UI.

- [ ] `AgentActivityModel` (@MainActor ObservableObject, singleton):
  агрегирует уже существующие сигналы — подключение `ClaudeIDEBridge`,
  состояние `ReviewAgentRunner` (idle/running/finished/failed), ожидающий
  `openDiff` из `DiffApprovalController`. Плюс новый канал статусов из Этапа 2.
- [ ] Тулбарный элемент (✨/sparkles): серый = агента нет; цветной = подключён;
  пульс = работает; badge = ждёт решения пользователя (openDiff / suggestions).
- [ ] Popover по клику: кто подключён (имя харнеса, если известно), что делает
  (последний статус/label), ожидающие решения со ссылками (перейти к diff /
  открыть Review), кнопка Stop для `ReviewAgentRunner`, хвост
  `.smotr-agent.log` (tail, read-only).
- [ ] Popover без подключённого агента — контекстные действия + палитра
  готовых промптов с кнопкой Copy (см. «Принцип UX» выше): состав промпта
  зависит от состояния (есть метки / нет меток / файл активен). Пресеты
  промптов — общий источник с Этапом 3 и командой ✈️ из Этапа 4.
- [ ] Подсказка следующего шага после «Place» в Review-сайдбаре:
  «N open marks — send to Claude ✈️» (сбрасывается отправкой/закрытием меток).
- [ ] Уведомление о завершении: когда агент закончил и появились новые
  suggestions — badge с числом на иконке Review-таба + ненавязчивый toast
  «Claude finished — N suggestions». Никаких модалок.
- [ ] Онбординг: пустое состояние Review-таба объясняет цикл тремя шагами
  (выдели → отметь → отправь ✈️) вместо одной строки.

Никакого нового протокола на этом этапе — только агрегация и отображение.

## Этап 2 — статус-канал: `editmdctl agent-status` + пакет хуков

Обратный канал «агент → приложение» для любого харнеса (порт паттерна agterm).

- [ ] Control-команда `agent-status <idle|active|completed|blocked>`
  с опциональным `--label <text>` (что именно делает агент) и `--harness <name>`.
  Роутер пишет в `AgentActivityModel`. Протокол не локализуется.
- [ ] `Resources/agent-status/editmd-agent-status.sh` — универсальный враппер:
  вне контекста EditMD (нет сокета) — молчаливый no-op; stdout/stderr подавлены;
  **всегда exit 0**. Разрешение пути к editmdctl: `$EDITMDCTL` → путь, зашитый
  установщиком → PATH.
- [ ] Адаптеры в том же каталоге:
  - Claude Code: фрагмент hooks для settings.json (lifecycle-события → враппер);
  - Codex: скрипт-адаптер (учесть ложные blocked до Auto Review — см. решение
    agterm в `agterm-codex-status.sh`);
  - pi: TypeScript-extension по образцу `agterm-status.ts`
    (`pi.on("agent_start"/"agent_settled")` → враппер);
  - shell: `integration.sh` для «голых» процессов.
- [ ] Установка хуков — из панели Integrations (Этап 4): враппер копируется в
  `~/.config/editmd/agent-status/`, конфиги харнесов правятся аккуратным merge
  (не перезаписывать чужие hooks), установка undoable/переустанавливаемая.

## Этап 3 — skill-пакет в бандле + обобщённый установщик

Документация, которую видит агент, — по структуре agterm.

- [ ] `Resources/agent-skill/`: `SKILL.md` (компактный: «я внутри EditMD-workspace?»,
  адресация, главные команды), `reference.md` (полный editmdctl + формат sidecar
  `.review.json` + `.smotr-queue.json` + семантика статусов/типов меток),
  `examples.md` (типовые сценарии: обработать очередь ревью, добавить suggest,
  открыть файл, сообщить статус), `troubleshooting.md`.
- [ ] Frontmatter: `when_to_use`-триггеры (editmd, editmdctl, review marks,
  sidecar, smotr-queue…), `allowed-tools: Bash(editmdctl *)`.
- [ ] Шаблоны промптов — единый источник: те же тексты, что показывает
  палитра промптов в popover ✨ (Этап 1), лежат рядом со skill-пакетом и
  подставляют контекст (путь файла, workspace, число меток). Один источник —
  ноль расхождений между «что подсказали» и «что реально работает».
- [ ] Обобщить `SkillInstaller`: установка пакета в `~/.claude/skills/editmd/`
  **и** `~/.codex/skills/editmd/` (+ легко добавить целевой каталог другого
  харнеса). Существующая установка `/smotr` не ломается.
- [ ] Команда меню Help ▸ Install Agent Skill… (дублируется в Integrations).

## Этап 4 — Settings ▸ Integrations: один дом для всего

- [ ] Новая вкладка настроек: статус-строки (control socket слушает; Claude
  IDE bridge подключён/нет; skill установлен в Claude/Codex; хуки установлены;
  MCP зарегистрирован) + кнопки Install/Reinstall рядом с каждой.
- [ ] Выбор команды агента для ✈️ (вместо захардкоженного
  `claude -p "/smotr -pr"`): пресеты Claude / Codex / Custom command
  (текстовое поле). `EDITMD_AGENT_CMD` остаётся override'ом для тестов.
- [ ] `ReviewAgentRunner` инжектит окружение спавнутому агенту:
  `EDITMD_ENABLED=1`, `EDITMD_SOCKET`, `EDITMD_QUEUE` (путь к очереди),
  `EDITMD_WORKSPACE` — discovery по образцу agterm.
- [ ] Install Command Line Tool… (symlink editmdctl в `/usr/local/bin` или
  инструкция), если ещё не сделано.

## Этап 5 — единый визуальный язык AI-правок

`openDiff`-approval и review-suggestions — одна семантика («AI предлагает,
человек решает»), должны выглядеть одинаково.

- [ ] Общие компоненты Accept/Decline (кнопки, цвета, шорткаты) для
  diff-approval и карточек suggest в Review-сайдбаре.
- [ ] Одинаковая зелёная подсветка replacement в обоих местах; статусы
  (accepted/declined/drifted) — одним словарём строк.
- [ ] Ожидающий openDiff виден в индикаторе Этапа 1 (badge + переход по клику).

## Этап 6 — MCP stdio proxy (богатый слой, опционален для v1)

- [ ] Новый target `editmd-mcp` в `project.yml`: тонкий бинарь
  stdio ↔ control socket, переиспользует `MCPProtocol.swift`.
- [ ] Tools: `get_active_document`, `get_selection`, `open_file`,
  `read_review_marks`, `add_review_mark`, `open_diff` (блокирующий — MCP-tool
  не отвечает до решения пользователя; continuation-инвариант сохраняется).
- [ ] Регистрация из Integrations: запись в `~/.codex/config.toml`,
  `.mcp.json` проектов, конфиги других MCP-харнесов. Merge, не перезапись.
- [ ] Не запускается под XCTest; протокол не локализуется.

## Этап 7 — грациозные внешние правки

Чужой харнесс без интеграции просто пишет файлы на диск — это тоже «AI ready».

- [ ] Если буфер не грязный — тихий auto-reload + toast «Reloaded from disk»
  (setting, по умолчанию on). Если грязный — текущий конфликтный путь, но с
  кнопкой «Show diff» (переиспользовать diff-вью openDiff).
- [ ] Индикатор Этапа 1 показывает «file changed on disk» как событие.

## Критерии приёмки

1. Codex/pi/shell-скрипт может: прочитать метки, добавить suggest, сообщить
   статус — только через файлы + editmdctl, следуя skill-пакету, без MCP.
1a. Тест дискаверабилити: пользователь, не читавший доков, ставит метку или
   кликает ✨ — и в два клика доходит до работающей команды (скопированный
   промпт выполняется в терминале без правок и даёт результат).
2. Индикатор в тулбаре честно отражает: нет агента / подключён / работает /
   ждёт решения — для Claude Code (bridge), для ✈️-агента и для внешнего
   харнеса, репортящего через `agent-status`.
3. Установка skill/hooks/MCP — по кнопке из Integrations, идемпотентна,
   не затирает чужие конфиги.
4. Все новые user-facing строки — en + ru в каталоге; протокол — только en.
5. Полный test suite зелёный; новые pure-функции (merge конфигов, парсинг
   статусов) покрыты unit-тестами; UI-этапы проверяются глазами пользователя.

## Порядок и объём

Рекомендуемая последовательность: 1 → 2 → 3 → 4 (ядро «AI ready», связная
история для UX) → 5 → 7 (полировка) → 6 (MCP, можно отдельным спринтом).
Этапы 1–4 — один спринт; 5–7 — второй.
