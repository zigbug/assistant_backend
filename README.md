# Personal Assistant Backend

Серверная часть персонального ассистента: задачи, проекты, события,
настройки и планы дня с генерацией через API.

## Технологии

- **Язык**: Dart 3.5+
- **HTTP фреймворк**: shelf + shelf_router
- **База данных**: SQLite через Drift (переход на PostgreSQL запланирован)
- **Деплой**: Docker + docker-compose

## Структура проекта

```
assistant_backend/
├── bin/
│   └── server.dart              # Точка входа HTTP сервера и все маршруты
├── lib/
│   └── src/
│       ├── config/
│       │   └── constants.dart   # Конфигурация из переменных окружения
│       └── database/
│           ├── database.dart    # Схема Drift, миграции, фабрика БД
│           ├── connection.dart  # Заготовка подключения к PostgreSQL (v2)
│           ├── tables/          # Описание таблиц
│           └── daos/            # DAO для каждой сущности
├── test/
├── Dockerfile
└── docker-compose.prod.yml
```

## Быстрый старт

```bash
# Установить зависимости
dart pub get

# Сгенерировать Drift код (нужно после изменения таблиц)
dart run build_runner build --delete-conflicting-outputs

# Запустить сервер
dart run bin/server.dart
```

По умолчанию сервер слушает `0.0.0.0:8081`,
health check: `http://localhost:8081/health`.

## Переменные окружения

Все настройки читаются из окружения (см. `.env.example`):

| Переменная | По умолчанию | Описание |
|---|---|---|
| `API_KEY` | `dev-key-change-me-in-production` | Ключ доступа, передаётся в заголовке `x-api-key` |
| `PORT` | `8081` | Порт HTTP-сервера |
| `HOST` | `0.0.0.0` | Интерфейс, на котором слушает сервер |
| `DATA_DIR` | платформенная директория данных | Каталог для файла SQLite-базы |

Локально база лежит в:
- Windows: `%APPDATA%/assistant_backend`
- Linux: `~/.local/share/assistant_backend`
- macOS: `~/Library/Application Support/assistant_backend`

## Аутентификация

Все эндпоинты требуют заголовок `x-api-key`, кроме `/health`.

```bash
curl -H "x-api-key: $API_KEY" http://localhost:8081/api/v1/tasks
```

## API Endpoints

### Задачи
- `GET /api/v1/tasks` — список задач (`?status=`, `?project_id=`, `?overdue=true`, `?scheduled=YYYY-MM-DD`)
- `POST /api/v1/tasks` — создать задачу
- `GET /api/v1/tasks/{id}` — получить задачу
- `PATCH /api/v1/tasks/{id}` — обновить задачу
- `DELETE /api/v1/tasks/{id}` — удалить задачу

### Проекты
- `GET /api/v1/projects` — активные проекты (`?archived=true`, `?include_archived=true`)
- `POST /api/v1/projects` — создать проект
- `GET /api/v1/projects/{id}` — проект со статистикой задач
- `PATCH /api/v1/projects/{id}` — обновить проект
- `PATCH /api/v1/projects/{id}/archive` / `unarchive` — архивация
- `DELETE /api/v1/projects/{id}` — удалить (запрещено при наличии задач)

### События
- `GET /api/v1/events` — события (`?filter=today|upcoming|all`, `?days=N`)
- `POST /api/v1/events` — создать событие
- `GET /api/v1/events/{id}`, `PATCH .../{id}`, `DELETE .../{id}`

### Настройки
- `GET /api/v1/preferences` — все настройки
- `PATCH /api/v1/preferences` — обновить несколько (`{"ключ": "значение"}`)
- `GET /api/v1/preferences/{key}`, `PUT .../{key}` — одна настройка

### Планы дня
- `POST /api/v1/daily-plans/generate?date=YYYY-MM-DD` — сгенерировать план (события + запланированные + просроченные задачи)
- `GET /api/v1/daily-plans/today` — план на сегодня
- `GET /api/v1/daily-plans/{date}` — план на дату
- `GET /api/v1/daily-plans/id/{id}` — план по ID
- `GET /api/v1/daily-plans/{id}/stats` — статистика выполнения
- `PATCH /api/v1/daily-plans/{id}` — статус плана / AI-комментарий
- `DELETE /api/v1/daily-plans/{id}` — удалить план
- `POST /api/v1/daily-plans/{id}/items` — добавить элемент
- `PATCH /api/v1/daily-plans/items/{id}` — отметить/перенести элемент
- `DELETE /api/v1/daily-plans/items/{id}` — удалить элемент

## Деплой

Автоматический: GitHub Actions (`.github/workflows/deploy.yml`) собирает
образы backend и MCP и выкатывает их на VPS при пуше в `main`.

Ручной запуск стека (backend + MCP):

```bash
cp .env.example .env   # заполнить API_KEY и MCP_SECRET_PATH
docker build -t assistant-backend:latest .
docker compose -f docker-compose.prod.yml --env-file .env up -d
```

SQLite-база хранится в volume `backend_data` и переживает пересоздание
контейнеров. Порты проброшены только на `127.0.0.1` — наружу трафик
отдаётся через reverse proxy.

## Лицензия

MIT
