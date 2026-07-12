# План подсветки кода во всех режимах EditMD

Дата: 2026-07-12

Статус: implementation brief

## Цель

Добавить зависящую от языка синтаксическую подсветку fenced code blocks во всех представлениях EditMD:

- Source;
- Visual;
- Preview;
- экспортированный PDF.

Один и тот же блок должен выглядеть согласованно во всех режимах, не менять исходный Markdown и корректно поддерживать как языки программирования, так и shell/Bash.

## Рекомендуемый движок

Использовать [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) 3.x как Swift Package. Это актуальная Swift-обёртка над [Highlight.js](https://github.com/highlightjs/highlight.js), работающая на macOS и возвращающая `NSAttributedString`.

- HighlighterSwift: MIT License.
- Highlight.js: BSD-3-Clause.
- Highlight.js поддерживает более 180 языков, включая Bash/Shell, Swift, JavaScript, TypeScript, Python, Rust, Go, C/C++, Java, Kotlin, SQL, YAML, JSON и Dockerfile.
- Зависимость должна быть зафиксирована на совместимой версии/ветке `3.x`, а не на `main`.
- JS/CSS-ресурсы должны поставляться внутри приложения. CDN и сетевые запросы во время работы не допускаются.

Не использовать старый `Highlightr`: с 2026 года проект объявлен неподдерживаемым и рекомендует HighlighterSwift.

Tree-sitter оставить возможным будущим направлением для IDE-функций. Для текущей задачи он избыточен: потребует подключения, лицензирования и сопровождения отдельных grammar-пакетов для каждого языка.

## Текущее состояние проекта

Основная инфраструктура уже есть:

- `swift-markdown` получает язык из info string fenced-блока;
- `MarkdownHighlighter.swift` создаёт `.codeBlockBody(language:)`;
- `MarkdownToAttributed.swift` и `MDBlock.Kind.codeBlock(language:)` сохраняют язык для Visual;
- `MarkdownHTML.swift` создаёт `<code class="language-…">` для Preview;
- сейчас токены раскрашиваются только для `yaml`/`yml`, причём отдельными реализациями в Source и Preview;
- Visual хранит язык, но показывает содержимое code block одним цветом;
- для тяжёлых документов уже существует режим без дорогой подсветки.

Markdown AST и формат хранения документа принципиально менять не нужно.

## Архитектура

Добавить единый слой подсветки:

```text
fenced code block
    │
    ├── code
    └── info string / language
            │
            ▼
CodeLanguageRegistry
            │
            ▼
CodeSyntaxHighlighter
    ├── нормализация языка
    ├── HighlighterSwift / Highlight.js
    ├── кэш и ограничения
    └── безопасный plain-text fallback
            │
            ├── Source: атрибуты в диапазоне исходного Markdown
            ├── Visual: атрибуты MDBlock-группы
            ├── Preview: HTML со span-классами
            └── PDF: тот же HTML-конвейер
```

Язык определяется первым токеном info string. Автоопределение языка должно быть выключено по умолчанию: на коротких блоках оно часто ошибается.

## 1. Зависимость и лицензии

1. Добавить HighlighterSwift через SPM в `EditMD.xcodeproj` и target приложения.
2. Зафиксировать совместимую версию 3.x.
3. Добавить в приложение/репозиторий уведомления о лицензиях HighlighterSwift и Highlight.js.
4. Проверить, что package resources попадают в собранное приложение и работают без сети.

## 2. Общий сервис

Добавить `EditMD/EditMD/Editor/CodeSyntaxHighlighter.swift`.

Предлагаемый интерфейс:

```swift
struct CodeHighlightRequest {
    let code: String
    let language: String?
    let appearance: CodeAppearance
}

struct CodeHighlightResult {
    let attributedString: NSAttributedString
    let resolvedLanguage: String?
}

@MainActor
final class CodeSyntaxHighlighter {
    static let shared = CodeSyntaxHighlighter()

    func highlight(
        code: String,
        language: String?,
        appearance: CodeAppearance
    ) -> CodeHighlightResult
}
```

Точный API можно изменить, но один сервис должен обслуживать Source и Visual, а правила языка, темы, fallback и кэш не должны дублироваться.

Требования к сервису:

- никогда не менять текст или число UTF-16 code units;
- проверять поддержку языка до вызова движка;
- при ошибке или неизвестном языке возвращать обычный моноширинный текст;
- не отдавать вызывающему коду фон всего блока и несовместимый paragraph style;
- кэшировать результат по `code + normalizedLanguage + theme/appearance`;
- иметь ограничение кэша по стоимости;
- позволять отменять или игнорировать устаревший результат;
- предоставлять детерминированный режим без autodetect.

## 3. Реестр языков и алиасов

Добавить `CodeLanguageRegistry` рядом с сервисом или в отдельном файле.

Минимальные алиасы:

| Info string | Язык движка |
|---|---|
| `sh`, `shell`, `zsh`, `console` | `bash` |
| `js` | `javascript` |
| `jsx` | `jsx` или поддерживаемая JS-грамматика |
| `ts` | `typescript` |
| `tsx` | `tsx` или поддерживаемая TS-грамматика |
| `py` | `python` |
| `rb` | `ruby` |
| `rs` | `rust` |
| `c++`, `cc` | `cpp` |
| `cs`, `c#` | `csharp` |
| `kt`, `kts` | `kotlin` |
| `yml` | `yaml` |
| `html` | `xml` |
| `md` | `markdown` |
| `text`, `txt`, `plaintext`, `nohighlight` | без подсветки |

Правила:

- trim whitespace;
- привести язык к lowercase;
- брать только первый токен из `swift title="A.swift"`;
- неизвестный язык не является ошибкой;
- оригинальный info string должен сохраняться при round trip без нормализации в самом документе.

## 4. Общая палитра

Добавить в `EditorTheme.swift` семантическую палитру кода, например:

```swift
struct CodeSyntaxPalette {
    let keyword: NSColor
    let string: NSColor
    let number: NSColor
    let comment: NSColor
    let type: NSColor
    let function: NSColor
    let variable: NSColor
    let attribute: NSColor
    let literal: NSColor
    let meta: NSColor
    let punctuation: NSColor
}
```

Цвета должны адаптироваться к light/dark appearance и встроенным темам EditMD. Фон code block, шрифт, размеры, отступы и скругление остаются под контролем EditMD.

На первом этапе допустимо адаптировать `atom-one-light` / `atom-one-dark`, но итоговое отображение Source, Visual и Preview должно опираться на согласованную палитру EditMD.

## 5. Source mode

Точка интеграции: `SourceTextView.Coordinator.highlightSource()`.

Для каждого `.codeBlockBody(language:)`:

1. Вычислить диапазон только содержимого code block, исключив открывающий и закрывающий fence.
2. Передать текст блока и язык общему сервису.
3. Перенести только разрешённые token attributes в соответствующий диапазон `NSTextStorage`.
4. Оставить fence и info string во вторичном Markdown-цвете.
5. Не заменять содержимое `NSTextStorage` новым attributed string.

Нельзя нарушить:

- selection и caret;
- undo/redo;
- line-number ruler;
- review highlights;
- dirty-line attributes;
- table alignment;
- Markdown-стили вокруг code block.

Текущий самописный YAML highlighter удалить после миграции fenced YAML. Frontmatter также можно подсвечивать тем же YAML-движком, сохранив особую обработку delimiters `---`.

Функция `sourceHighlightedLines(...)`, используемая diff/review UI, должна применять тот же сервис либо сознательно оставаться на дешёвом fallback. Решение зафиксировать тестом, чтобы Source и diff не расходились случайно.

## 6. Visual mode

Точки интеграции: `MarkdownToAttributed.renderCodeBlock()` и/или `VisualTextView.applyPresentation()`.

Важно подсвечивать code block целиком, а не каждую строку отдельно:

1. Собрать соседние параграфы с одинаковым `MDBlock.group` и `.codeBlock(language:)`.
2. Объединить их текст через `\n`.
3. Один раз токенизировать весь блок.
4. Разложить атрибуты обратно по исходным параграфам.

Это требуется для многострочных строк и комментариев.

При применении результата сохранить внутренние атрибуты EditMD:

- `.mdBlock`;
- `.mdStyle`;
- ссылки/служебные метаданные;
- selection;
- typing attributes.

При наборе пересвечивать только изменённую `MDBlock.group`, а не весь документ. После Enter, split/join, paste и смены языка блока группа должна пересчитываться корректно.

## 7. Preview mode

Точка интеграции: `MarkdownHTML.HTMLBodyVisitor.visitCodeBlock()`.

Текущий специальный путь `yaml`/`yml` заменить общей HTML-подсветкой.

Предпочтительный вариант:

- использовать локально встроенный Highlight.js;
- генерировать безопасные `span` с классами `hljs-*`;
- сопоставить классы с общей палитрой через CSS;
- при неизвестном языке выводить HTML-escaped plain text;
- `plaintext`/`nohighlight` никогда не передавать в autodetect.

Info string обязательно экранировать как HTML attribute. Код нельзя вставлять в HTML без escaping или через небезопасный `innerHTML` из исходного Markdown.

Лучше генерировать уже подсвеченный HTML до окончательной загрузки страницы. Если подсветка выполняется JS внутри `WKWebView`, Preview и PDF должны явно ожидать завершения выполнения скрипта.

## 8. PDF export

`PDFExporter.swift` должен использовать тот же HTML и CSS, что Preview.

Критерии:

- PDF содержит те же token colors;
- экспорт не зависит от сети;
- экспорт не начинается до завершения подсветки;
- неизвестные языки и ошибки движка не ломают PDF;
- light/dark или выбранная export theme применяется детерминированно.

## 9. Настройки

Добавить в Settings раздел Code Highlighting:

- `Syntax highlighting`: On/Off;
- `Auto-detect language for unlabelled blocks`: Off по умолчанию;
- тема: Follow editor / Light / Dark, если это действительно требуется текущей моделью настроек;
- подсветка очень больших блоков: Off по умолчанию либо внутреннее ограничение без отдельного UI.

Первая версия может обойтись без выбора языка через UI: Markdown info string уже является основным интерфейсом.

При выключенной подсветке layout, фон code block, моноширинный шрифт и язык в Markdown сохраняются.

## 10. Производительность и concurrency

- Подсвечивать только code blocks, не весь Markdown как код.
- Debounce редактирования: ориентировочно 80–150 мс.
- Пересвечивать изменённый блок, когда возможно.
- Блоки больше 50–100 КБ оставлять plain text; точный предел определить измерениями.
- При `document.isHeavy` сохранить существующий дешёвый режим.
- Токенизацию по возможности выполнять вне main thread.
- Изменять `NSTextStorage` только на main actor.
- Каждому запросу присваивать revision/generation; устаревший результат не применять.
- Не создавать новый экземпляр JS runtime на каждый блок или каждое нажатие клавиши.
- Ограничить `NSCache.totalCostLimit` суммарным объёмом UTF-16 текста/атрибутов.

Перед merge измерить:

- документ с 50–100 небольшими блоками;
- один блок на 5 000 строк;
- непрерывный набор внутри Bash/Swift блока;
- переключение Source ↔ Visual ↔ Preview;
- смену appearance.

## 11. Тесты

Добавить `EditMD/EditMDTests/CodeSyntaxHighlighterTests.swift` и расширить существующие тесты Source/Visual/HTML/PDF.

Обязательная матрица:

- Bash: команды, переменные, строки, комментарии;
- Swift, JavaScript, TypeScript, Python, JSON, YAML, SQL;
- алиасы `sh`, `shell`, `js`, `ts`, `py`, `yml`;
- неизвестный язык;
- пустой info string;
- `text`, `plaintext`, `nohighlight`;
- `swift title="A.swift"`;
- Unicode и emoji перед блоком и внутри него;
- CRLF;
- `~~~bash`;
- fence длиннее трёх символов;
- backticks внутри кода;
- несколько блоков разных языков;
- многострочные строки и комментарии;
- пустой code block;
- смена light/dark темы;
- большой блок и heavy document;
- безопасное HTML escaping кода и info string.

Регрессионные проверки:

- plain text до и после подсветки идентичен;
- переключение режимов не меняет Markdown;
- Visual round trip сохраняет язык;
- undo/redo не получает attribute-only операций;
- caret и selection не прыгают;
- Source review/diff/dirty highlights сохраняются;
- Preview и PDF получают token classes/colors;
- неизвестный язык даёт plain fallback, а не пустой блок или ошибку.

Snapshot-тесты Preview должны проверять существенные token classes и escaping, а не всю нестабильную HTML-разметку страницы.

## Этапы реализации

### Этап 1 — фундамент

- SPM dependency;
- notices/licenses;
- `CodeLanguageRegistry`;
- `CodeSyntaxHighlighter`;
- палитра;
- unit tests сервиса.

### Этап 2 — Source

- fenced blocks;
- Bash и основные языки;
- YAML migration;
- frontmatter migration;
- heavy-document fallback;
- Source/diff tests.

### Этап 3 — Visual

- подсветка целой MDBlock-группы;
- инкрементальное обновление;
- сохранение служебных атрибутов;
- editing и round-trip tests.

### Этап 4 — Preview и PDF

- общий highlighted HTML;
- CSS палитры;
- escaping;
- синхронизация PDF export;
- HTML/PDF tests.

### Этап 5 — настройки и оптимизация

- пользовательский toggle;
- опциональный autodetect;
- debounce/cache/cancellation;
- performance tests;
- удаление старого дублирующего YAML-кода.

Каждый этап должен собираться и проходить тесты независимо. Не следует оставлять Source, Visual и Preview на разных движках как конечное состояние.

## Критерии готовности

Функция готова, когда этот блок:

````markdown
```bash
for file in *.md; do
  echo "$file"
done
```
````

имеет корректную Bash-подсветку в Source, Visual, Preview и экспортированном PDF, при этом:

- Markdown остаётся побайтно/текстово неизменным;
- язык сохраняется при Visual round trip;
- неизвестный язык безопасно отображается обычным кодом;
- переключение темы обновляет все режимы;
- undo, selection, review marks и dirty-line rendering не ломаются;
- набор текста не вызывает заметных зависаний;
- приложение работает полностью офлайн;
- все сторонние лицензии учтены.

## Ожидаемые файлы изменений

- `EditMD/EditMD.xcodeproj/project.pbxproj`
- `EditMD/EditMD/Editor/CodeSyntaxHighlighter.swift` — новый
- `EditMD/EditMD/Editor/EditorTheme.swift`
- `EditMD/EditMD/Editor/MarkdownHighlighter.swift` — только если потребуется точнее выделять body/fence
- `EditMD/EditMD/Editor/SourceTextView.swift`
- `EditMD/EditMD/Editor/MarkdownToAttributed.swift`
- `EditMD/EditMD/Editor/VisualTextView.swift`
- `EditMD/EditMD/Editor/MarkdownHTML.swift`
- `EditMD/EditMD/Views/MarkdownPreviewView.swift`
- `EditMD/EditMD/Editor/PDFExporter.swift`
- `EditMD/EditMD/Views/EditorSettings.swift`
- `EditMD/EditMD/Views/SettingsView.swift`
- `EditMD/EditMDTests/CodeSyntaxHighlighterTests.swift` — новый
- существующие тесты Source/Visual/MarkdownHTML/PDF по необходимости
- файл third-party notices/licenses

Список ориентировочный: не добавлять изменения в файл только ради соответствия списку.

## Замечания для последующего code review

При review отдельно проверить:

1. Не меняется ли строка документа при применении attributed attributes.
2. Не попадают ли attribute-only операции в undo stack.
3. Правильно ли пересчитаны UTF-16 ranges для emoji и non-ASCII.
4. Исключены ли fence lines из токенизации Source.
5. Подсвечивается ли Visual-блок целиком, а не построчно.
6. Нет ли сетевых/CDN-зависимостей.
7. Экранируются ли код и info string в HTML.
8. Не запускается ли JS runtime заново на каждое нажатие.
9. Отбрасываются ли устаревшие async-результаты.
10. Совпадают ли Preview и PDF.
11. Работают ли `nohighlight`, неизвестные языки и heavy fallback.
12. Добавлены ли тексты лицензий и copyright notices.
