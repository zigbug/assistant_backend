# Roadmap: Assistant Backend & MCP Integration

## Архитектурные решения (зафиксировано)
- **MCP-сервер**: реализован отдельно, репозиторий `assistant_mcp` (Dart, пакет `mcp_dart`), развёрнут на сервере, бэкенд предоставляет ему HTTP API.
- **AI-логика**: временно делегируется десктопному приложению Qwen (бэкенд выступает как хранилище данных и источник контекста).
- **Аутентификация**: пока используем простой `API_KEY` в заголовках. JWT/OAuth2 добавим позже по мере необходимости.
- **Время**: все даты и время (`DateTime`) в базе данных и API строго в **UTC**. Конвертация в локальный часовой пояс происходит на стороне клиента (Flutter) с учетом `timezone` из `Preferences`.
- **База данных**: **только SQLite** (Drift). Переход на PostgreSQL **отменён** — решение принято после этапа 1. Заготовка `lib/src/database/connection.dart` не используется и может быть удалена.

## Этап 1: База данных и DAO ✅ ЗАВЕРШЁН
- [x] Инициализация проекта и настройка Drift. ~~PostgreSQL + SQLite~~ → **только SQLite**, миграция на PostgreSQL отменена.
- [x] Определение схемы БД (таблицы: `Projects`, `Tasks`, `Events`, `DailyPlans`, `DailyPlanItems`, `Preferences`, `Notes`, `AiLessons`).
- [x] Реализация DAO (Data Access Objects) для всех таблиц:
  - [x] `TasksDao`: CRUD операции, фильтрация по статусу/проекту, матрица Эйзенхауэра, reactive streams.
  - [x] `ProjectsDao`: CRUD операции, архивирование.
  - [x] `DailyPlansDao`: создание плана, привязка задач к временным слотам.
  - [x] `PreferencesDao`: чтение/запись настроек (включая `timezone`).
  - [x] `AiLessonsDao`: добавление и получение контекста для обучения агента.
  - [x] `EventsDao`: CRUD для событий и встреч.
  - [x] `NotesDao`: быстрые заметки с возможностью promotion в задачу.
- [ ] Написание unit-тестов для DAO (с использованием SQLite in-memory). → перенесено в [Этап 5](#этап-5-качество)

## Этап 2: HTTP API (Shelf) — завершён, кроме 2.7

### 2.1 Базовая инфраструктура ✅ ЗАВЕРШЕНО
- [x] Настройка базового `shelf` сервера.
- [x] Middleware: логирование запросов (`logRequests`), проверка `API_KEY` (`apiKeyMiddleware`).
- [ ] CORS — **не реализован**. Зависимость `shelf_cors_headers` есть в `pubspec.yaml`, но в пайплайне `bin/server.dart` не подключена.
- [x] Health check endpoint (`GET /health`).
- [x] Фабричная функция `createDatabase()` для создания БД (SQLite, файл или in-memory для тестов).
      ~~с поддержкой PostgreSQL (prod)~~ → **отменено**, см. архитектурные решения.
- [x] Insomnia коллекция для тестирования API (`api/insomnia/`, 48 запросов).

### 2.2 Tasks API ✅ ЗАВЕРШЕНО
- [x] `GET /api/v1/tasks` — список активных задач.
- [x] `POST /api/v1/tasks` — создание задачи.
- [x] `GET /api/v1/tasks/<id>` — получение одной задачи по ID.
- [x] `PATCH /api/v1/tasks/<id>` — частичное обновление задачи (статус, поля, reschedule).
- [x] `DELETE /api/v1/tasks/<id>` — удаление задачи.
- [x] `GET /api/v1/tasks?status=todo&project_id=1` — фильтрация через query-параметры.
- [x] Фильтрация по дедлайну: `?overdue=true`, `?scheduled=YYYY-MM-DD`.

### 2.3 Projects API ✅ ЗАВЕРШЕНО
- [x] `GET /api/v1/projects` — список проектов (активные по умолчанию, `?include_archived=true` для всех).
- [x] `POST /api/v1/projects` — создание проекта (name + опциональный color в hex).
- [x] `GET /api/v1/projects/<id>` — получение проекта со статистикой задач (taskCount, taskStats).
- [x] `PATCH /api/v1/projects/<id>` — обновление проекта (name, color).
- [x] `PATCH /api/v1/projects/<id>/archive` — архивирование проекта.
- [x] `PATCH /api/v1/projects/<id>/unarchive` — восстановление из архива.
- [x] `DELETE /api/v1/projects/<id>` — удаление (запрещено если есть привязанные задачи, возвращает 409).

### 2.4 Preferences API ✅ ЗАВЕРШЕНО
- [x] `GET /api/v1/preferences` — получение всех настроек как JSON-объект.
- [x] `PATCH /api/v1/preferences` — пакетное обновление нескольких настроек.
- [x] `GET /api/v1/preferences/<key>` — получение одной настройки по ключу.
- [x] `PUT /api/v1/preferences/<key>` — создание/обновление одной настройки.

### 2.5 Events API ✅ ЗАВЕРШЕНО
События — жёсткие блоки времени (встречи, созвоны, дни рождения). Нужны, чтобы AI не ставил задачи во время уже запланированных встреч.
- [x] `GET /api/v1/events` — список событий с фильтрацией (`?filter=today|upcoming|all`, `?days=N`).
- [x] `POST /api/v1/events` — создание события (с валидацией ISO 8601 даты и enum recurrence).
- [x] `GET /api/v1/events/<id>` — получение одного события.
- [x] `PATCH /api/v1/events/<id>` — частичное обновление события.
- [x] `DELETE /api/v1/events/<id>` — удаление события.

### 2.6 Daily Plans API ✅ ЗАВЕРШЕНО
Планы дня — центральная фича ассистента. Генерация, просмотр и управление элементами.
- [x] `POST /api/v1/daily-plans/generate?date=YYYY-MM-DD` — генерация плана (идемпотентная, с базовой эвристикой: события + scheduled-задачи + просроченные).
- [x] `GET /api/v1/daily-plans/today` — получение плана на сегодня.
- [x] `GET /api/v1/daily-plans/<date>` — получение плана на конкретную дату (UTC).
- [x] `GET /api/v1/daily-plans/id/<id>` — получение плана по ID (для MCP с сохранённым контекстом).
- [x] `PATCH /api/v1/daily-plans/<id>` — обновление метаданных плана (status: draft/confirmed/done, aiComment).
- [x] `DELETE /api/v1/daily-plans/<id>` — удаление плана и всех элементов (каскадно).
- [x] `POST /api/v1/daily-plans/<id>/items` — добавление элемента вручную (task/event/breakSlot/habit).
- [x] `PATCH /api/v1/daily-plans/items/<id>` — обновление элемента (status, reschedule, note).
- [x] `DELETE /api/v1/daily-plans/items/<id>` — удаление элемента.

### 2.7 Notes API — Быстрые заметки
Статус: **не начат**. DAO (`NotesDao`) готов и зарегистрирован в схеме, HTTP-эндпоинтов нет.
- [ ] CRUD для заметок (`/api/v1/notes`).
- [ ] Promotion заметки в задачу (`POST /api/v1/notes/<id>/promote`).
- [ ] Фильтрация по тегам и статусу (inbox, archived).

### 2.8 Служебные эндпоинты ✅ ЗАВЕРШЕНО (добавлено после 2026-08-21)
- [x] `GET /api/v1/time` — текущее время сервера, часовой пояс из Preferences, UTC offset.
- [x] `X-Server-Time-Utc` в заголовке каждого ответа + `serverTimeUtc` в теле объектных JSON-ответов.
- [x] Повторяющиеся задачи: `recurrence`, `repeatInterval`, `repeatEndDate`, `parentId` + серверный
      материализатор серий на 30 дней вперёд (идемпотентный, перезапуск каждые 6 ч).

## Этап 3: Интеграция с MCP ✅ ЗАВЕРШЁН
MCP-сервер вынесен в отдельный репозиторий `assistant_mcp` (Dart, `mcp_dart`), `dart analyze` — без замечаний.
- [x] Выбор стека для MCP — **Dart** (пакет `mcp_dart`, протокол MCP 2026-07-28) и инициализация отдельного репозитория.
- [x] HTTP-клиент к бэкенду (`ApiClient`) с авторизацией по `x-api-key` и проверкой доступности бэкенда при старте.
- [x] Два транспорта: `stdio` (локально) и Streamable HTTP (Qwen Desktop / VPS), флаг `--transport`,
      DNS-rebinding protection через белый список `MCP_ALLOWED_HOSTS`.
- [x] 9 tools: Tasks (`list_tasks`, `create_task`, `update_task`, `delete_task`),
      Plans (`get_today_plan`, `generate_plan`, `get_plan_stats`, `update_plan_item`),
      Time (`get_current_time`).
- [x] Деплой MCP в Docker + общий `docker-compose.prod.yml` (сервис `mcp`).
- [ ] Проектирование и документирование OpenAPI/Swagger спецификации.
- [ ] Пакетное получение контекста для MCP (задачи + предпочтения + уроки AI) — сейчас AI ходит
      в бэкенд несколькими отдельными вызовами. `GET /api/v1/time` уже закрывает потребность в моменте времени.
- [ ] Эндпоинты для `Notes` и `AiLessons` (DAO готовы, HTTP-роутов нет).

## Этап 4: CI/CD и Деплой ✅ ЗАВЕРШЁН
- [x] GitHub Actions: билд образов backend + MCP и выкатка на VPS по SSH при пуше в `main`
      (`.github/workflows/deploy.yml`, ручной запуск через `workflow_dispatch`).
- [x] Dockerfile для бэкенда (multi-stage, build_runner, non-root user).
- [x] Развёртывание на VPS (Ubuntu) через Docker Compose: backend + MCP, SQLite в volume `backend_data`,
      порты на `127.0.0.1` (наружу — reverse proxy), health-check в пайплайне.
- [ ] Тесты и линтинг в CI (сейчас пайплайн только собирает и деплоит).

## Этап 5: Качество
- [ ] Unit-тесты для DAO (SQLite in-memory) — папка `test/` пустая.
- [ ] Тесты для MCP tools (`assistant_mcp/test/` содержит только placeholder).
- [ ] Подключить CORS, если понадобится доступ из браузера/веб-клиента.
- [ ] Переменная `HOST` задокументирована в README, но не используется: сервер всегда слушает `0.0.0.0`
      (`bin/server.dart`). Либо применить `AppConstants.serverHost`, либо убрать из документации.
- [ ] Удалить неиспользуемую заготовку `lib/src/database/connection.dart` (дублирует `createDatabase`,
      PostgreSQL отменён).
- [ ] Разобрать 49 info-линтов `dart analyze` (в основном `avoid_print` — перейти на пакет `logging`,
      который уже подключён).

---
*Последнее обновление: 2026-10-02*
