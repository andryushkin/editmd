# Встроенные плагины EditMD

EditMD поддерживает только плагины, скомпилированные вместе с приложением. Новый плагин добавляет разработчик на Swift и регистрирует в `BuiltInPluginRegistry`. Документ не может загрузить JavaScript, внешний bundle или скачанный executable code.

## Модель

- `BuiltInMarkdownPlugin` описывает метаданные и активацию на конкретном документе.
- `BuiltInPluginRegistry` — единственный список доступных плагинов.
- Frontmatter включает и настраивает плагин для файла; глобального исполнения «для всех документов» нет.
- Результат активации — value-only semantic tokens с UTF-16 ranges. Плагин не получает произвольный доступ к view, файлам, сети или фоновым процессам.
- Общий snapshot потребляют три независимых пути: Source spans/lint, Visual attributed model/round-trip и Preview HTML/WebKit bridge.
- Клик меняет только проверенный source range через обычный undo path документа. Если текст или offset уже изменился, запоздалое событие отклоняется.
- Settings ▸ Plugins показывает скомпилированные плагины и их frontmatter keys; пользовательские toggles не нужны, потому что активация принадлежит документу.

Чтобы добавить следующий встроенный плагин, нужны: Swift-тип с parser/activation, регистрация, представление во всех затронутых режимах, undoable mutation, тесты ranges/round-trip и описание изменения в `docs/HISTORY.md`.

## Multi-checkbox

Плагин активируется только при валидной конфигурации минимум из двух уникальных односоставных markers:

```yaml
---
editmd:
  plugins:
    multi-checkbox:
      states:
        - marker: "-"
          label: Не скачано
          icon: "sf:circle"
        - marker: "x"
          label: Попытка №1
          icon: "sf:arrow.down.circle"
        - marker: "+"
          label: Скачано
          icon: "sf:checkmark.circle.fill"
        - marker: "?"
          label: PMID под вопросом
          icon: "emoji:❓"
        - marker: "X"
          label: Безуспешно
          icon: "sf:xmark.circle.fill"
          strikethrough: true
---
```

Поля состояния:

- `marker` — обязательный символ между `[` и `]`; сейчас один UTF-16 unit, чтобы `[x]` всегда занимал три source units.
- `label` — необязательное доступное имя и tooltip; по умолчанию marker.
- `icon` — `sf:<system-name>`, `emoji:<text>` или обычный текст; по умолчанию marker.
- `strikethrough` — необязательный boolean, по умолчанию `false`.

Порядок `states` задаёт цикл; последнее состояние переходит в первое. Например, при порядке выше клик меняет `[-] → [x] → [+] → [?] → [X] → [-]`.

Токены работают в list items, обычном тексте и table cells. В больших Visual-таблицах основной сценарий — отдельный status cell, как в `PMID_DOWNLOAD_LIST.md`. Frontmatter, fenced/inline code, Markdown links/images, wiki-links и math остаются исходным синтаксисом и не становятся интерактивными status widgets.

Активация заменяет checkbox-семантику для всего файла. `[ ]`, `[x]` и `[X]`, которых нет в `states`, отображаются буквально и не получают обычный двухсостоянийный toggle. В файле без конфигурации стандартные GFM checkbox продолжают работать без изменений.
