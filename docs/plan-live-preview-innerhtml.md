# План быстрого Live Preview в split view через `innerHTML`

Дата: 2026-07-13

Статус: реализован и покрыт тестами 2026-07-13

## Цель

При редактировании Markdown в Source или Visual правая панель Preview должна
быстро и непрерывно показывать актуальный результат, не мешая набору текста.

Целевое поведение:

- первая правка после паузы появляется в Preview практически сразу;
- при непрерывном наборе Preview обновляется несколько раз в секунду;
- после остановки ввода гарантированно показывается последняя ревизия текста;
- рендер не отбирает фокус у Source/Visual и не вызывает скачки прокрутки;
- тяжёлый документ не блокирует ввод частыми полными перерисовками.

Ориентир для обычного документа: p95 от `textDidChange` до обновлённого DOM —
не более 100–150 мс. Для тяжёлого документа важнее отзывчивость редактора и
гарантированное финальное обновление, чем тот же интервал.

## Текущее состояние

Путь данных уже правильный:

1. `SourceTextView.Coordinator.textDidChange` записывает `tv.string` в
   `document.content` при каждом изменении.
2. Visual синхронно сериализует attributed buffer и также обновляет
   `document.content` при каждом изменении.
3. `MarkdownDocument.content.didSet` отправляет `objectWillChange`, поэтому
   SwiftUI вызывает `MarkdownPreviewView.updateNSView`.

Узкое место находится в Preview:

- действует leading-edge throttle с фиксированным интервалом 250 мс;
- `previewHTMLPage` заново строит всю страницу, включая CSS и JS;
- HTML строится на main actor;
- каждое обновление вызывает `loadHTMLString`;
- новая навигация уничтожает DOM, после чего `didFinish` повторно наносит
  review marks и восстанавливает прокрутку.

Простое уменьшение `renderInterval` вернёт полный тяжёлый конвейер почти на
каждый символ. Основная оптимизация — оставить страницу и JS-контекст живыми,
а заменять только HTML-фрагмент документа.

## Решение

Preview становится постоянным HTML-каркасом:

```html
<body>
  <main id="preview-content"></main>
</body>
```

Полная страница загружается через `loadHTMLString` только:

- при первом создании `WKWebView`;
- при изменении настроек, которые запекаются в CSS/JS;
- при переходе от страницы без KaTeX-ресурсов к документу с формулами;
- при другой редкой смене возможностей HTML-каркаса.

Обычная правка Source/Visual проходит по короткому пути:

```text
document.content
    → markdownHTMLRender
    → HTML-фрагмент body
    → window.editMDReplacePreview(...)
    → #preview-content.innerHTML = html
    → повторная инициализация динамического содержимого
```

Нельзя присваивать `document.body.innerHTML`: это уничтожит постоянную часть
страницы, JS-мосты, функции синхронизации прокрутки и установленные обработчики.

## 1. Разделить HTML-каркас и содержимое

Точки изменения: `MarkdownHTML.swift`, `MarkdownPreviewView.swift`.

1. Сохранить `previewHTMLPage` как полный автономный документ для первого
   показа и `PDFExporter`.
2. Для live-обновления использовать существующий `markdownHTMLRender`, который
   уже возвращает `(body, hasMath)`.
3. Добавить в полную страницу стабильный контейнер `#preview-content`.
4. Вынести настройку динамических элементов из одноразового page-load кода в
   повторно вызываемую функцию `window.editMDHydratePreviewContent()`.
5. Первый full render должен вставлять тот же body-фрагмент, что и последующие
   обновления, чтобы два пути не расходились.
6. Скрипты страницы сейчас лежат в `<body>` ПОСЛЕ фрагмента (page-script и
   KaTeX-блок, `MarkdownHTML.swift:1089–1403`) — при введении контейнера они
   остаются вне `#preview-content`, иначе первый же `innerHTML` их удалит.
   Там же инициализировать `window.editMDPreviewRevision = 0` — сравнение
   ревизии с `undefined` всегда false.

`PDFExporter` продолжает получать полностью собранную страницу. Live DOM-путь
не должен менять PDF и его ожидание KaTeX/layout.

## 2. Добавить атомарную замену DOM

В HTML-каркасе определить одну публичную функцию, например:

```javascript
window.editMDReplacePreview = async function (payload) {
    if (payload.revision < window.editMDPreviewRevision) return false;

    const root = document.getElementById('preview-content');
    root.innerHTML = payload.html;
    window.editMDPreviewRevision = payload.revision;

    editMDHydratePreviewContent();
    await editMDWaitForPreviewLayout();
    editMDRestorePreviewPosition(payload.position);
    return true;
};
```

HTML передавать через `WKWebView.callAsyncJavaScript(..., arguments:)`, а не
интерполировать в строку JavaScript. Это сохраняет кавычки, Unicode и большие
фрагменты без ручного escaping.

После `innerHTML` необходимо:

1. повторно включить task-checkboxes и привязать их индекс;
2. заново привязать wiki/local-link действия либо перевести их на event
   delegation от постоянного контейнера;
3. заново создать кнопки Copy у code/quote blocks;
4. явно вызвать KaTeX для новых `.math`-элементов;
5. инвалидировать кэш markdown→DOM scroll anchors;
6. выровнять line-number gutter;
7. повторно нанести актуальные review marks;
8. дождаться хотя бы следующего layout frame перед восстановлением прокрутки.

Предпочтительно перевести клики по task/wiki/local links и Copy на один
делегированный обработчик постоянного контейнера. Если это окажется слишком
широким изменением, первая версия может идемпотентно перепривязывать обработчики
после каждой замены. Существующий selection-скрипт (`WKUserScript`,
`selectionchange` на `document`) переживает `innerHTML` и правок не требует.

Два обязательных защитных механизма живого каркаса:

1. Пока каркас грузится (между `loadHTMLString` и `didFinish`),
   fragment-обновления в JS не отправлять — они попадут в старый или пустой
   DOM. Хранить последний pending payload и применять его из `didFinish`.
2. Ошибка `callAsyncJavaScript` (или ответ `false`) → один полный reload
   каркаса. Это постоянный runtime-fallback, а не только страховка на время
   миграции.
3. `webViewWebContentProcessDidTerminate` обязателен: сегодня каждый рендер
   сам чинит страницу новым `loadHTMLString`, а долгоживущий каркас после
   смерти WebContent-процесса молча перестанет применять обновления. Handler:
   полный reload + сброс `shellHasMathAssets`, applied revision и scroll state.

## 3. Сохранить прокрутку и фокус

`innerHTML` не перезагружает страницу, но высота блоков над viewport может
измениться. Одного старого `scrollY` недостаточно.

Правила восстановления:

1. В split view приоритет имеет `lastFollowedPosition` — логическая позиция
   Markdown, уже полученная от Source/Visual.
2. Если логической позиции нет, перед заменой DOM сохранить текущую позицию
   через существующее преобразование `mdPositionForY` (сейчас замкнуто внутри
   IIFE страницы — экспонировать на `window`).
3. После hydrate/layout восстановить её через существующий
   `syncScrollToMdPosition`/`programmaticScroll`.
4. После KaTeX и загрузки изображений ещё раз инвалидировать anchors; второй
   scroll-pass выполнять только если layout действительно сдвинул целевой
   якорь.
5. Программное восстановление не должно отправляться обратно редактору как
   пользовательский scroll и создавать feedback loop.
6. `WKWebView` не становится first responder во время live-обновления.

Путь полного Preview сохраняет ручную прокрутку пользователя: editor-follow
используется только в split view.

## 4. Управлять ревизиями и частотой обновления

Добавить тестируемый `PreviewRenderScheduler` либо эквивалентное состояние в
Coordinator:

- `requestedRevision` — последняя запрошенная ревизия;
- `appliedRevision` — последняя ревизия, подтверждённая JS;
- не более одного HTML-рендера одновременно;
- во время активного рендера хранится только последний pending request;
- завершившийся результат применяется только монотонно по revision;
- после завершения сразу запускается последняя накопленная ревизия;
- при teardown ожидающие Task отменяются, а поздние результаты игнорируются;
- разделить обязанности `lastRenderedContent`: сейчас поле ставится ДО
  загрузки и служит одновременно guard'ом от повторного рендера и источником
  длины текста для scroll-функций (`scroll(toMarkdownPosition:)`). В
  async-конвейере guard — по requested revision, а длина для скролла — по
  применённому контенту, иначе скролл целится в текст, которого ещё нет в DOM.

После перехода на `innerHTML` уменьшить минимальный интервал для обычных
документов, ориентировочно до 80–100 мс. Точное значение выбрать по замерам.
Для `document.isHeavy` оставить более редкое обновление, например 250 мс, с
обязательным trailing render последнего текста.

Нельзя использовать чистый trailing debounce: при непрерывном наборе Preview
останется старым до полной остановки. Нужны leading update, ограничение частоты
во время серии и финальный trailing update.

## 5. Вынести построение фрагмента с main thread

Переход на `innerHTML` убирает WebKit navigation, но не стоимость cmark,
синхронной подсветки кода и подготовки data URI изображений. Вторым этапом:

1. На main actor собрать неизменяемый `PreviewRenderRequest`:
   content, revision, URL/baseDir, gutter и снимок настроек.
2. Сделать request из `Sendable`-значений; не читать singleton-настройки из
   фоновой задачи.
3. Выполнить `markdownHTMLRender` на последовательной фоновой очереди/actor.
4. Учесть, что `CodeSyntaxHighlighter` уже сериализует Highlight.js своим lock;
   проверить это Thread Sanitizer и конкурентными тестами.
5. Вернуть `PreviewRenderResult(body, hasMath, revision)` на main actor и
   передать его в JS только если Coordinator ещё жив.
6. Кэшировать data-URI картинок по (путь, mtime): при интервале 80–100 мс
   каждый рендер заново читает с диска и кодирует в base64 все локальные
   картинки документа.

Если вынос всего рендера сразу конфликтует со Swift 6 isolation, допустимо
выпустить `innerHTML`-этап отдельно, но замерить main-thread stalls и оставить
фоновый рендер обязательным продолжением задачи.

## 6. KaTeX, настройки и полный reload

Текущая страница встраивает около 640 КБ KaTeX только когда в документе есть
формулы. Сохранить ленивое поведение:

- Coordinator хранит `shellHasMathAssets`;
- `hasMath == false → true` при отсутствии ресурсов вызывает один полный reload;
- после появления ресурсов дальнейшие формулы обновляются через `innerHTML`;
- `true → false` не требует reload;
- изменение CSS-настроек, темы, gutter-конфигурации или размеров может пока
  использовать существующий full-rerender путь;
- после full reload обновляются `shellHasMathAssets`, применённая revision и
  scroll state.

В будущем CSS-параметры можно менять через custom properties без reload, но это
не входит в текущую задачу.

## 7. Review marks

`loadHTMLString` сейчас вызывает `applyReviewHighlights` из `didFinish`.
У `innerHTML` навигации и `didFinish` не будет, поэтому новый путь обязан явно:

1. завершить hydrate/layout;
2. вызвать существующий `applyReviewHighlights`;
3. не использовать диапазоны от более старой ревизии текста;
4. повторно нанести wash после асинхронного recompute якорей ReviewModel.

Review marks не должны участвовать в генерации основного HTML-фрагмента: они
остаются отдельным DOM-decoration слоем, как сейчас.

## 8. Тесты

### Unit

- `markdownHTMLRender` возвращает тот же body для full page и live fragment;
- контейнер и `editMDReplacePreview` присутствуют в `previewHTMLPage`;
- scheduler немедленно запускает первую ревизию после паузы;
- серия быстрых правок применяет монотонные ревизии и заканчивается последней;
- медленный старый рендер не может заменить новый;
- heavy-режим ограничивает частоту, но не теряет финальное обновление;
- teardown отменяет pending update;
- обновление, запрошенное до `didFinish` каркаса, применяется после загрузки,
  а не теряется и не уходит в старый DOM;
- переход `hasMath false → true` выбирает full reload, остальные изменения —
  fragment update.

### Интеграционные

- ввод в Source быстро меняет DOM Preview;
- ввод в Visual быстро меняет тот же DOM;
- заголовки, списки, таблицы, frontmatter, wiki/local links и изображения;
- fenced code с подсветкой обеих палитр;
- добавление/редактирование/удаление формулы;
- task checkbox после нескольких `innerHTML`-обновлений отправляет один toggle,
  а не несколько накопленных обработчиков;
- Copy button после нескольких обновлений также срабатывает один раз;
- review wash исчезает/перемещается вместе с изменённым якорем;
- позиция split-scroll остаётся на том же Markdown-якоре;
- полное Preview сохраняет ручную прокрутку;
- PDF-output не изменился.

### Performance

Замерить `textDidChange → render start → render finish → DOM applied` для:

- короткой заметки без кода;
- KitchenSink;
- документа с несколькими code blocks;
- документа с KaTeX;
- heavy markdown около существующего порога.

В Instruments проверить main-thread hangs, частоту JS-вызовов и отсутствие
серии полных WebKit navigation при наборе текста.

## 9. Порядок реализации

1. Добавить контейнер и повторно вызываемый hydrate без изменения текущего
   `loadHTMLString`-пути; покрыть HTML-тестами.
2. Реализовать fragment update через `callAsyncJavaScript` и revision guard,
   включая pending-очередь на время навигации каркаса, fallback на full reload
   при ошибке JS и `webViewWebContentProcessDidTerminate`.
3. Подключить повторную инициализацию task/link/copy/KaTeX/gutter/review.
4. Перенести сохранение split-scroll с `didFinish` на completion fragment update.
5. Добавить scheduler и уменьшить интервал для обычных документов.
6. Вынести `markdownHTMLRender` с main thread.
7. Прогнать unit/integration/performance проверки и выбрать окончательные
   интервалы по результатам.

Каждый шаг должен оставлять рабочий full-reload fallback. Удалять старый путь
можно только после ручной проверки Source, Visual, full Preview, split Preview и
PDF.

## Критерии приёмки

- Обычный текст в Source и Visual виден справа в пределах 100–150 мс p95.
- При непрерывном наборе Preview обновляется, а не ждёт остановки ввода.
- После остановки DOM соответствует последнему `document.content`.
- Ввод не подвисает из-за cmark/highlight.js/WebKit navigation.
- В live-режиме нет `loadHTMLString` на каждый символ/интервал.
- Не скачивают scroll, caret и focus; feedback loop прокрутки не вернулся.
- Работают task toggles, links, Copy, KaTeX, gutter и review marks.
- Тяжёлый документ остаётся редактируемым и получает финальный render.
- Full Preview и PDF не имеют визуальных регрессий.

## Риски и решения

| Риск | Решение |
|---|---|
| Прямые обработчики теряются после `innerHTML` | Общий hydrate или event delegation от постоянного контейнера |
| KaTeX `<script>` внутри `innerHTML` не выполняется | Явный вызов рендера; один full reload при первом появлении ресурсов |
| Старый фоновой результат приходит позже нового | Монотонная revision и один render in flight |
| DOM меняет высоту и сдвигает viewport | Восстановление по Markdown-якорю после layout, не только по `scrollY` |
| Review wash исчезает вместе со старым DOM | Явный `applyReviewHighlights` после fragment update |
| Частый cmark/highlight.js тормозит ввод | Фоновый render, latest-only queue и отдельный heavy-интервал |
| Обработчики накапливаются после hydrate | Идемпотентная привязка или единый делегированный listener |
| Fragment-вызов уходит в JS во время загрузки каркаса | Pending payload применяется из `didFinish`; ошибка JS → полный reload |
| WebContent-процесс умирает, каркас молча перестаёт обновляться | `webViewWebContentProcessDidTerminate` → reload каркаса + сброс состояния |
| Raw HTML ведёт себя иначе при `innerHTML` | Зафиксировать безопасную семантику тестом; пользовательские `<script>` не исполнять |

## Вне задачи

- Инкрементальный Markdown AST или блочный diff DOM.
- Полная виртуализация Preview.
- Перенос syntax highlighting в JavaScript внутри `WKWebView`.
- Обновление Preview CSS-настроек без full reload.
- Изменение формата Markdown, Visual attributed model или PDF-конвейера.
