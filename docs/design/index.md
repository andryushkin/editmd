# EditMD — экраны на ревью

HTML-прототипы всех экранов приложения. Токены (цвета/шрифты/отступы) сняты с
реального кода: `EditorTheme.swift` (палитра System/GitHub), `EditorSettings.swift`
(per-mode шрифт/отступы/элементы), `MarkdownHTML.swift` (Preview CSS),
`ContentView.swift` (тулбар agterm-стиля, сплит, статус-строка). Один документ
(«Release Notes — v27») прогнан через все три режима — удобно сравнивать рендер.
Все прототипы theme-aware: переключаются light/dark по системной теме.

## Основные режимы

- **[01_source.html](01_source.html)** — Source: сырой markdown, моноширинный,
  подсветка по элементам + линтер (dotted-подчёркивания, бейджи ✕/⚠ в статусе).
- **[02_visual.html](02_visual.html)** — Visual: WYSIWYG, пропорциональный шрифт,
  маркеры рисуются (буллиты/чекбоксы), таблица NSTextTable, code-панель.
- **[03_preview.html](03_preview.html)** — Preview: read-only WKWebView, GitHub-CSS
  (H1/H2 с нижней линией, кликабельные чекбоксы).

## Компоновка

- **[04_sidebar.html](04_sidebar.html)** — сайдбар-оглавление (⌃⌘S) + editor (= вкладка Outline в новом сайдбаре).
- **[10_workspace_sidebar.html](10_workspace_sidebar.html)** — 🆕 редизайн сайдбара: вкладка **Files** — несколько workspace (папки, всегда видны, сворачиваются) сверху, отдельные файлы из Finder — ниже; глаз показывает/прячет скрытые, у скрытой строки — «вернуть». Клик по файлу = замена в том же окне.
- **[05_split.html](05_split.html)** — сплит редактор + живой Preview (⌥⌘P).

## Settings-окно (⌘,)

- **[06_settings_general.html](06_settings_general.html)** — General: тема,
  оформление, базовые цвета.
- **[07_settings_source.html](07_settings_source.html)** — Source: шрифт/отступы/
  колонка + грид элементов (H1–H6, Bold/Code/Link/Quote), живой Sample.
- **[08_settings_visual.html](08_settings_visual.html)** — Visual: то же + Spacing.
- **[09_settings_preview.html](09_settings_preview.html)** — Preview: то же +
  Line height + включённая колонка чтения.

> Размечай прямо на прототипах в smotr-вью: `pin`/`element` (правка макета в точке
> или по селектору), `question`/`fix`/`rewrite`/`comment`. Метки лягут рядом в
> `*.review.json`.
