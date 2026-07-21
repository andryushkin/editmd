# План 11 — Типографика Visual: доводка под современный Apple-стиль

Статус: черновик (2026-07-22)
Зависимости: нет. Этапы идут по порядку, каждый = отдельный коммит + проверка глазами
пользователя (screencapture недоступен). Scope — только Visual: Source и Preview (со своей
системой тем `PreviewTheme`) не трогаем, кроме мест, где Visual-константы физически общие.

Общие требования: прочитать `CLAUDE.md` и разделы `docs/HISTORY.md` про Visual/round-trip;
сборка и тесты через `xcodebuild` из корня; `xcodegen generate` при новых файлах.

---

## Диагноз (скриншоты 2026-07-22 + код)

Текущий облик — имитация GitHub (`EditorTheme.github`, портирован из swift-markdown-ui).
Для нативного macOS-редактора это чужой язык: экранная типографика Apple строит иерархию
размером, жиром и воздухом, а не цветом и линиями.

| Факт в коде | Проблема на экране |
| --- | --- |
| Нет `lineSpacing`/`lineHeightMultiple` нигде в Visual — дефолтный leading SF | Плотный, «слипшийся» текст; абзацы читаются тяжело |
| Inline-код: красный `#d1242f`/`#ff7b72` + `.backgroundColor` серый (`VisualCoordinatorPresentation.swift:554`) | Красные пятна доминируют над контентом; фон — прямоугольник, некрасиво рвётся на переносе строки |
| Ссылки: accent + постоянный `underlineStyle` (`:543`) | Подчёркивание всего подряд — web-стиль, не Apple |
| H1/H2: линии-дивайдеры под заголовком (`headingDividerRanges`) | GitHub-изм; Apple заголовки не подчёркивает |
| Заголовки: before 14/10, after 8 — почти симметрично | Заголовок не «прилипает» к своему разделу (нужно before:after ≈ 2–3:1) |
| Маркеры списков, номера, чекбоксы — все accent-синие | Синий шум; в Notes/HIG маркеры нейтральные, акцент — только интерактив |
| Blockquote: синий бар + серый wash (`quoteBackground`) | Тяжёлая «плашка»; у Apple цитата — тонкий серый бар + приглушённый текст |
| Таблицы: рамка каждой ячейки 0.5pt + серая заливка header (native `NSTextTableBlock` и island-грид) | Excel/GitHub-сетка; Apple-таблицы — только горизонтальные hairlines |
| Битое/отсутствующее изображение — крошечный глиф U+FFFC | Выглядит как мусор (скриншот test-all-elements, стр. 90) |
| Выполненная задача: strikethrough + secondary | Двойное погашение; в Notes достаточно серого |

## Целевая шкала (дефолты при базе 15pt; всё × пользовательский `sizeScale`/`spacingScale`)

Иерархия — по мотивам HIG type ramp (Large Title 26 / Title 1 22 / Title 2 17):

- **Body**: 15 regular, line height ≈ 1.3 (см. этап 1), paragraphSpacing 8.
- **H1**: ×1.75 ≈ 26, bold; before 26, after 8.
- **H2**: ×1.45 ≈ 22, semibold; before 22, after 7.
- **H3**: ×1.2 ≈ 18, semibold; before 16, after 6.
- **H4**: ×1.07 ≈ 16, semibold; **H5**: ×1.0, semibold; **H6**: ×1.0, semibold + `secondaryColor`.
  Before для H4–H6 12, after 5.
- **Код** (inline и блочный): моно ×0.88 ≈ 13 (сейчас «−1pt» ≈ 14 — моно оптически крупнее
  пропорционального того же кегля).
- Tracking не трогаем: `NSFont.systemFont` сам переключает оптические размеры SF.

Числа — стартовые значения для ревью, а не догма: после каждого этапа пользователь смотрит
глазами и числа подгоняются.

## Инварианты (обязательны на каждом этапе)

- **Presentation-only**: ни один этап не меняет байты markdown и сериализацию. Round-trip
  suite зелёный; plain string у storage до/после presentation pass идентичен.
- `test-all-elements.md` — живой файл-фикстура, app пишет в него на лету: его diff не коммитить.
- Все цвета — динамические `NSColor(name:)` light/dark; не запекать `NSApp.effectiveAppearance`.
- Пользовательские настройки продолжают работать: меняем **дефолты** (`ElementStyles.init`,
  константы `EditorTheme`), per-element overrides и `spacingScale` уважаются как сейчас.
- Константы — в `EditorTheme` (единственная baseline-тема после спринта 3); новую систему
  тем не строить.
- `MDBlock.hash` остаётся O(1); тяжёлые payload в значениях атрибутов не хешировать.
- Native-таблицы и island-грид меняются синхронно из одних констант.
- PDF-экспорт и split-режим используют тот же рендер — прогнать глазами и их.

---

## 11.1 Вертикальный ритм: leading и интервалы

Файлы: `VisualCoordinatorPresentation.swift`, `EditorTheme.swift`.

- Ввести leading для текстовых абзацев: `lineHeightMultiple ≈ 1.3` (body, списки, цитаты,
  заголовки). **Не** трогать: table islands (там `minimumLineHeight` резервирует высоту
  грида), строки code block (плотный листинг, ≈1.2), параграфы с math-attachment и
  изображениями (attachment-глифы сами задают высоту — проверить, что multiple их не режет
  и не даёт скачков базовой линии).
- paragraphSpacing 6 → 8; списки: item spacing 2 → 3, отступ после последнего элемента
  списка 6 → 8.
- Заголовки: before/after из шкалы выше (before:after ≈ 3:1).
- Смешанная строка (body + inline-код разного кегля) не должна «дышать» по высоте —
  проверить на строке с кодом, ссылкой и bold одновременно.
- Приёмка: три файла со скриншотов ревью (agent-инструкция, `test-all-elements.md`,
  демо таблиц) в light и dark; сравнение бок-о-бок с теми же файлами в Apple Notes / Bear.
  Настройка Settings ▸ Visual ▸ spacing масштабирует всё пропорционально, на 1.0 — новый вид.

## 11.2 Инлайн-элементы: код, ссылки, done-задачи

Файлы: `VisualCoordinatorPresentation.swift` (`applyDerivedInlineDecorations`),
`EditorTheme.swift`, `VisualNSTextViewDrawing.swift`.

- **Inline-код**: цвет = `textColor` (дефолт `inlineCodeColor` меняется с красного на
  нейтральный; пользовательский пикер в Settings остаётся). Фон — нейтральный
  `ghAlpha(light: 0.055, dark: 0.09)`. Pill-отрисовка: закруглённые (r≈4) плашки по runs
  в `drawBackground` с горизонтальным паддингом ~3pt вместо квадратного `.backgroundColor`
  (механика уже есть у code panels; runs собирать в presentation pass, как quotes/bullets).
  На переносе строки — две аккуратные плашки, а не растянутая полоса. Если pill окажется
  дорогим на больших документах — fallback: оставить `.backgroundColor`, но нейтральный.
  Math-runs (tint как у кода) получают тот же нейтральный цвет.
- **Ссылки** (обычные и wiki): accent-цвет, **без** постоянного подчёркивания; underline
  появляется на hover (у Visual уже есть link-hover механика — проверить) или только под
  курсором при ⌘. Если hover-underline потребует нового tracking-механизма — просто убрать
  подчёркивание (Apple Notes так и делает).
- **Done-задачи**: серый `secondaryColor` без strikethrough (перечёркивание остаётся только
  у явного `~~del~~`). Плагинные task-токены с `state.strikethrough` — по конфигу токена,
  как сейчас.
- Приёмка: скриншот-1-файл (плотный текст с инлайн-кодом в каждом абзаце) перестаёт «рябить»;
  ссылки читаются как интерактив без подчёркивания; round-trip и paste-тесты зелёные.

## 11.3 Заголовки

Файлы: `EditorSettings.swift` (`ElementStyles.init`), `EditorTheme.swift`,
`VisualNSTextViewDrawing.swift`, `VisualCoordinatorPresentation.swift`.

- Новая шкала/веса из таблицы выше (дефолты `ElementStyle`; H1 остаётся bold, остальные
  semibold; H6 дополнительно `secondaryColor` как дефолтный цвет элемента).
- **Убрать дивайдеры под H1/H2** (`headingDividers` + отрисовка). Поле
  `headingDividerColor` в теме пометить как unused или удалить вместе с draw-кодом.
- Setext-заголовки автоматически подтягиваются (это те же `.heading`).
- Приёмка: `test-all-elements.md` (там все уровни + setext): иерархия читается без линий,
  H1 не «чернее» страницы; пользовательские override размера/веса из Settings работают.

## 11.4 Блочные элементы: списки, цитаты, HR, code panel

Файлы: `VisualNSTextViewDrawing.swift`, `EditorTheme.swift`,
`VisualCoordinatorPresentation.swift`.

- **Маркеры списков**: точка меньше (≈3.5–4pt) и нейтральная (`markerColor`/`secondaryColor`
  вместо accent); номера ordered — `monospacedDigitSystemFont`, `secondaryColor`,
  выравнивание по правому краю колонки маркера (единицы/десятки не пляшут). Чекбоксы
  остаются accent (интерактив), но выравниваются по cap-height первой строки.
- **Blockquote**: бар — нейтральный серый (тон `separatorColor`, чуть темнее), ширина 3 → 2;
  фон-wash `quoteBackground` → прозрачный; текст цитаты — `secondaryColor` (дефолт
  `elements.quote.color`). Callouts сохраняют свой цветной бар/иконку — их палитра
  типо-специфична и остаётся.
- **HR**: hairline 1px `separatorColor`, вертикальные отступы ≈16/16.
- **Code panel**: радиус 6 → 8, фон оставить; шрифт листинга по шкале ×0.88; проверить
  внутренние отступы панели после смены leading (11.1).
- Приёмка: `test-all-elements.md` + любой файл с вложенными списками и цитатами; blockquote
  из скриншота (стр. 112) выглядит спокойной цитатой, а не панелью-алертом.

## 11.5 Таблицы

Файлы: `VisualCoordinatorPresentation.swift` (`.tableCell`), `VisualNSTextViewDrawing.swift`
(island-грид), общие константы — в `EditorTheme`.

- Убрать вертикальные внутренние линии и рамку по бокам: горизонтальные hairlines между
  строками + линия 1pt под header. Native: `NSTextBlock.setWidth(_:type:for:edge:)`
  по-рёберно вместо общей рамки; island: не рисовать колоночные сепараторы (drag-ручки и
  hit-testing колонок сохраняются — проверить, что resize/контекстное меню живут без линий;
  при hover колонки сепаратор можно показывать).
- Header: без серой заливки, текст semibold; если без заливки header теряется — едва заметная
  `ghAlpha(0.03/0.05)`.
- Паддинг ячеек 6 → 8–9; зебра `tableRowBackground` — выключить по умолчанию (константа
  остаётся).
- Native и island обязаны выглядеть одинаково — приёмка на демо-файле таблиц И на таблице
  больше `maxNativeTableCells` (island): один и тот же файл в обоих режимах отрисовки.
- Тесты таблиц/буфера обмена зелёные; редактирование ячеек, drag строк, resize колонок — живы.

## 11.6 Изображения и хвосты

Файлы: `VisualCoordinatorPresentation.swift` (`attachImages`), `VisualNSTextViewDrawing.swift`.

- Placeholder битого/отсутствующего изображения: вместо голого глифа — панель с иконкой
  `photo` и alt-текстом/именем файла, `secondaryColor`, фон как у code panel, фикс-высота
  ≈60pt. Успешно загруженные изображения: скругление углов (r≈6) при отрисовке attachment.
- Пройтись по мелочи после этапов 1–5: выравнивание чекбоксов/маркеров при новом leading,
  отступ первой строки документа, интервалы вокруг math-блоков.
- Обновить `docs/HISTORY.md` (раздел спринта) и, если менялись дефолты Settings, — скриншоты
  дизайна не трогаем (`docs/design/*` — исторические макеты).

## 11.7 (Опционально, отдельное решение) Максимальная ширина колонки текста

Не начинать без явного подтверждения пользователя. Опция Settings ▸ Visual: cap ширины
текстовой колонки ≈720pt с центрированием (стиль iA Writer/Craft) через
`textContainerInset`/`lineFragmentPadding` — но это трогает геометрию гаттера
(`EditorFieldGeometry`), table islands и код полей, поэтому — отдельный мини-план после
приёмки 11.1–11.6.

---

## Верификация спринта целиком

1. Полный suite + `git diff --check`; отдельно round-trip и paste-тесты.
2. Глаза пользователя: три файла со скриншотов ревью в light/dark, плюс PDF-экспорт одного
   из них и split-режим (Source+Visual) — интервалы не ломают sync-scroll.
3. Бок-о-бок с Apple Notes (тот же текст скопировать туда): вертикальный ритм и «вес»
   страницы сопоставимы.

## Открытые вопросы (дефолты выбраны, но пользователь может переиграть)

1. Ссылки без подчёркивания совсем vs underline on hover — дефолт: без, hover если дёшево.
2. Дивайдеры H1/H2 — дефолт: убрать совсем (не настройка).
3. Красный inline-код уходит из дефолта; кто хочет GitHub-вид — пикер цвета в Settings.
4. Зебра таблиц — дефолт: выключена.
5. 11.7 (ширина колонки) — делать ли вообще.
