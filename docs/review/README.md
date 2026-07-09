# Review (smotr)

Веб-вью для разметки артефактов автор→Клод. **Движок внешний** — живёт в `~/Server/smotr` (свой git-репо), сюда не копируется. Здесь только тонкий лаунчер `run` + конфиг `../../.smotr.json`.

## Запуск

```bash
./docs/review/run                 # http://localhost:8000
./docs/review/run --port 9000 --no-open
```

Открывается дерево из `contentDir` (`docs/`). Размечаемое: `.md`, `.html`, картинки, а также прототипы экранов в `docs/design/`. Метки сохраняются рядом в `*.review.json`.

## Улучшения движка

Правки логики (`serve.py`/`vendor`) — только в `~/Server/smotr`, затем `python3 ~/Server/smotr/selftest.py` и PR туда (прилетает всем проектам). В этом репо движок не форкается.
