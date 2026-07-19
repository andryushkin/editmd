# План 10 — «wikillm ready»: инструменты wikillm-агента + персистентный индекс workspace

Статус: в работе (решения ревью 2026-07-19 внесены)
Зависимости: план 02 (link index), план 06 (vault-lint), план 07 (workspace
search), план 09 (AI ready), CPU-сага LinkIndex (см. `docs/HISTORY.md`)
Разблокирует: работу LLM-агентов с wikillm-вольтами (WoL и др.) через EditMD
без самостоятельного обхода вольта; мгновенный старт индекса.

## Термин

**wikillm** — паттерн компилируемой базы знаний (Karpathy WikiLLM gist):
LLM однажды компилирует знание в структурированную wiki из markdown-файлов
и дальше поддерживает её. Три слоя: raw sources (read-only) → wiki
(LLM-генерируемые MD: entity/concept/summary/synthesis pages) → schema
(CLAUDE.md/AGENTS.md). Навигация index-first: агент сначала читает
`index.md`-каталог, выбирает узлы, затем читает страницы. Периодический
lint: orphans, dead links, противоречия. WoL (`~/Documents/wikillm/wol`,
референсный вольт ~7000 md) — вариация этого паттерна; его нормативные
документы: `docs/wikillm_concept.md`, `docs/index-constitution.md`.

**EditMD считается «wikillm ready», когда:**

1. Агент, работающий с wikillm-вольтом, получает граф знаний от EditMD, а не
   обходит вольт сам: outgoing links, backlinks, wiki-резолюция, outline,
   vault-lint findings, workspace search — через агентские поверхности
   EditMD (control socket / skill).
2. Линк-индекс workspace персистентен: живёт файлом внутри workspace,
   переживает перезапуск (старт = валидация, не ре-парс) и читается внешними
   инструментами без запущенного EditMD.
3. Одиночные markdown-файлы (lite/loose, вне adopted workspace) не строят и
   не сохраняют индекс — как и сейчас (lazy-модель, single-file map в памяти).

## Контекст и существующий код

Прочитай перед началом: `CLAUDE.md`, `docs/HISTORY.md` (разделы «CPU-сага
LinkIndex/vault-lint», «AI ready», «Vault-lint», «Workspace search»).

- `Views/LinkIndex.swift` — граф: `outgoing`/`backlinks`/`headings`,
  `scanCache: [URL: FileScanEntry]` (parse-кэш по (mtime, size) + resolve-кэш
  по fingerprint окружения), скоуп = активный workspace
  (`WorkspaceModel.linkIndexRoots`), scanCache переживает переключение.
- `Editor/LinkScan.swift` — `OutgoingLink` (kind/rawTarget/heading/label/
  line/utf16Offset/context/resolved/candidates).
- `Editor/VaultLint.swift`, `Views/VaultLintModel.swift` — findings по
  снапшоту индекса; полный прогон только по требованию.
- `Views/WikiLinkResolver.swift` — basename-индекс `[[target]]` → URLs.
- `Views/WorkspaceSearchSidebar.swift` (`WorkspaceSearchModel`) — поиск.
- `Integration/ControlServer.swift` / `ControlRouter.swift` /
  `ControlProtocol.swift` — control socket + `editmdctl`; имена команд с
  точечными неймспейсами (`marks.list`, `diff.show`); router двухфазный
  (main state + deferred disk work); протокол не локализуется.
- `Integration/ClaudeIDETools.swift` — **важно**: `tools/list` IDE-канала
  зафиксирован, CLI фильтрует его по своей таблице и лишний инструмент может
  оборвать handshake. wikillm-инструменты в IDE MCP НЕ добавляются — только
  control socket (и, позже, MCP stdio proxy из плана 09).
- `Integration/SkillInstaller.swift` + skill `editmd` — agent-facing
  документация; новые команды обязаны попасть туда же.

## Этап 1 — персистентный индекс workspace

`.editmd/link-index.json` в корне adopted workspace.

**Запись.** После успешного полного скана (не отменённого), off-main,
атомарно (tmp + rename), с debounce — авто-сейв единственного файла не
перезаписывает индекс целиком чаще раза в N секунд. Записывается только для
workspace из `linkIndexRoots`; при `roots.isEmpty` (lite/loose) — никогда,
`.editmd/` в чужих папках не создаётся.

**Формат.** Версионированный JSON, детерминированный и диффабельный: файлы
отсортированы по относительному пути, ссылки — в порядке документа. На файл:
`path` (относительный от корня workspace), `mtime` (unix, миллисекунды),
`size`, `headings`, `links` [{kind, rawTarget, heading?, label, line,
utf16Offset, resolvedPath?, candidates?}]. Плюс `version`, `scannedAt`,
`root`-marker. Пути — только относительные: файл переносим вместе с вольтом.

**Чтение.** При старте (warm scan) и при первом скане нового workspace: файл
парсится off-main, каждая запись валидируется по (mtime, size) через stat —
валидные сеют `scanCache`, изменённые/исчезнувшие ре-парсятся как обычно.
Итог: холодный запуск на неизменном вольте = walk + stat'ы вместо минут
парсинга (главный оставшийся дорогой путь из CPU-саги).

**Резолв.** Персистится `resolvedPath` per link, но валидность резолва
проверяется как сейчас — fingerprint окружения. Для персиста fingerprint
обязан стать стабильным между запусками: текущий `Hasher` (случайный
process seed) заменяется на явный FNV-1a по тем же компонентам (roots
относительно корня, wiki-индекс, набор путей). Инвариант O(1)-хешей
NSTextStorage не затрагивается — это отдельный хэш индекса.

**Инварианты.**
- Никакого disk I/O индекса на main actor.
- Walk уже скипает скрытые каталоги → `.editmd/` не попадает в скан и в
  fingerprint; собственная запись файла не триггерит рескан.
- Повреждённый/чужой версии файл молча игнорируется (полный скан как без
  него) и перезаписывается следующим сканом.
- Коммитить ли `.editmd/` в git — решение владельца вольта; EditMD не пишет
  в `.gitignore` (открытый вопрос №1).

**Тесты.** Round-trip записи/чтения; валидация по mtime (изменённый файл
ре-парсится, остальные сеются); повреждённый JSON игнорируется; loose-файл
не создаёт `.editmd/`; стабильность fingerprint между «запусками»
(два independent вычисления совпадают); детерминизм байтов файла при
неизменном вольте (git-friendly).

## Этап 2 — wikillm-инструменты в control socket

Новые команды `editmdctl` (JSON-выход, английский, не локализуется):

- `links.outgoing <path>` — ссылки файла: kind, rawTarget, resolved | dead |
  ambiguous (+candidates), line, context.
- `links.backlinks <path>` — обратные рёбра: source, line, context,
  utf16Offset (прыжок агент делает через `open` + offset).
- `links.resolve <target> [--from <path>]` — wiki-резолюция basename с
  тем же tie-break, что у навигации (sibling wins).
- `outline <path>` — заголовки с уровнями и offsets (уже есть
  `markdownOutline`; вопрос только сериализации).
- `lint.workspace` / `lint.file <path>` — vault-lint findings (dead/
  ambiguous/orphan/dead-heading) в JSON; полный прогон по требованию —
  использует существующий `runNow()`-путь, не подписку.
- `search <query> [--limit N]` — результаты workspace search.
- `index.status` — готов ли индекс, для какого root, возраст персиста,
  счётчики файлов/ссылок; агент по нему решает, ждать или работать.

Роутер: main-фаза читает опубликованные словари LinkIndex (без stat'ов),
deferred-фаза — всё дисковое. Если индекс не готов — честный ответ
`indexing` с прогрессом, не блокировка сокета. Скоуп ответов = активный
workspace (контракт `linkIndexRoots`); path вне активного workspace →
явная ошибка `outside-active-workspace` (агент понимает, что открыть файл =
переключить скоуп).

**Тесты.** По каждой команде: happy path, файл вне workspace, индекс не
готов; two-phase инвариант роутера (нет disk I/O в main-фазе) — по образцу
существующих control-тестов.

## Этап 3 — skill и документация для агента

- Skill `editmd` дополняется разделом «wikillm tools»: когда использовать
  index.status/links.*/lint.* вместо самостоятельного grep/walk вольта;
  формат `.editmd/link-index.json` для чтения без запущенного EditMD.
- `AgentPromptCatalog` — готовый промпт «работай с вольтом через editmdctl».
- (Отложено, из плана 09) MCP stdio proxy поверх тех же команд — для
  харнесов без Bash. Не в этом плане.

## Не делаем (граница с самим wikillm)

- WoL-специфика — `graph/edges.jsonl`, `concepts/`, генерация `index.md`,
  конституции — принадлежит pipeline вольта; EditMD их не пишет и не
  валидирует (vault-lint не учит правилам index-constitution).
- Никакой записи в файлы вольта, кроме `.editmd/link-index.json`.
- IDE MCP `tools/list` не расширяется (см. Контекст).

## Решения ревью (пользователь, 2026-07-19)

1. **Не коммитить.** `.editmd/` делается само-игнорирующимся: EditMD пишет
   внутрь `.editmd/.gitignore` с `*` — вольтовый `.gitignore` не трогается.
2. **`index.dump` не нужен** — агент читает `.editmd/link-index.json`
   напрямую; формат документируется в skill.
3. Персистится только активный workspace (запись после его full scan);
   неактивные живут в памяти (`scanCache`) и записываются, когда становятся
   активными и проходят свой скан.
4. **Акцент этапа 3:** skill обязан явно переучивать агента — не «читай и
   строй граф сам», а «спроси EditMD» (editmdctl / индексный файл); это
   главный смысл термина wikillm ready.
