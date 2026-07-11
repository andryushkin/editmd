---
title: EditMD Kitchen Sink
tags: [demo, markup, editmd]
author: EditMD
---

# Kitchen Sink — демо-разметка

Файл для проверки **всех** режимов: Source · Visual · Preview.

## Заголовки

# H1
## H2
### H3
#### H4
##### H5
###### H6

## Inline

Обычный текст, **жирный**, *курсив*, ***оба***, ~~зачёркнутый~~, `инлайн-код`, ==выделение==.

Ссылка: [EditMD](https://example.com) и wiki-link [[Note|alias]].

## Списки

- маркированный
  - вложенный
- ещё пункт

1. нумерованный
2. второй
   1. вложенный

- [ ] задача
- [x] сделано

## Цитаты

> Внешняя цитата
>
> > Вложенная цитата
>
> снова внешняя

## Код

```swift
func hello() {
    print("Hello, EditMD")
}
```

```yaml
name: demo
enabled: true
items:
  - one
  - two
```

## Таблица

| Left | Center | Right |
| :--- | :----: | ----: |
| a | b | c |
| **bold** | `code` | 42 |

## Разделитель

---

## Картинка

![placeholder](icon.png)

## Смешанный абзац

Текст после таблицы и разделителя — smoke для C1–C4.
