# Roadmap: Assistant Backend & MCP Integration

## Архитектурные решения (зафиксировано)
- **MCP-сервер**: будет реализован отдельно (Dart или Go), развернут на сервере, бэкенд будет предоставлять ему HTTP API.
- **AI-логика**: временно делегируется десктопному приложению Qwen (бэкенд выступает как хранилище данных и источник контекста).
- **Аутентификация**: пока используем простой `API_KEY` в заголовках. JWT/OAuth2 добавим позже по мере необходимости.
- **Время**: все даты и время (`DateTime`) в базе данных и API строго в **UTC**. Конвертация в локальный часовой пояс происходит на стороне клиента (Flutter) с учетом `timezone` из `Preferences`.

## Этап 1: База данных и DAO ✅ ЗАВЕРШЁН
- [x] Инициализация проекта и настройка Drift (PostgreSQL + SQLite для локальной разработки).
- [x] Определение схемы БД (таблицы: `Projects`, `Tasks`, `Events`, `DailyPlans`, `DailyPlanItems`, `Preferences`, `Notes`, `AiLessons`).
- [x] Реализация DAO (Data Access Objects) для всех таблиц:
  - [x] `TasksDao`: CRUD операции, фильтрация по статусу/проекту, матрица Эйзенхауэра, reactive streams.
  - [x] `ProjectsDao`: CRUD операции, архивирование.
  - [x] `DailyPlansDao`: создание плана, привязка задач к временным слотам.
  - [x] `PreferencesDao`: чтение/запись настроек (включая `timezone`).
  - [x] `AiLessonsDao`: добавление и получение контекста для обучения агента.
  - [x] `EventsDao`: CRUD для событий и встреч.
  - [x] `NotesDao`: быстрые заметки с возможностью promotion в задачу.
- [ ] Написание unit-тестов для DAO (с использованием SQLite in-memory).

## Этап 2: HTTP API (Shelf) — Текущий приоритет

### 2.1 Базовая инфраструктура ✅ ЗАВЕРШЕНО
- [x] Настройка базового `shelf` сервера.
- [x] Middleware: логирование запросов, проверка `API_KEY`, CORS.
- [x] Health check endpoint (`GET /health`).
- [x] Фабричная функция `createDatabase()` для создания БД с поддержкой SQLite (dev) и PostgreSQL (prod).
- [x] Insomnia коллекция для тестирования API (`api/insomnia/`).

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
- [ ] CRUD для заметок (`/api/v1/notes`).
- [ ] Promotion заметки в задачу (`POST /api/v1/notes/<id>/promote`).
- [ ] Фильтрация по тегам и статусу (inbox, archived).

## Этап 3: Интеграция с MCP (Будущий этап)
- [ ] Проектирование и документирование OpenAPI/Swagger спецификации.
- [ ] Реализация специфичных эндпоинтов для MCP (пакетное получение контекста: задачи + предпочтения + уроки AI).
- [ ] Выбор стека для MCP (Dart `mcp` пакет или Go) и инициализация отдельного репозитория.

## Этап 4: CI/CD и Деплой
- [ ] Настройка GitHub Actions для тестирования и линтинга.
- [ ] Dockerfile для бэкенда.
- [ ] Развертывание на VPS (Ubuntu) с использованием Docker Compose (бэкенд + PostgreSQL).

---
*Последнее обновление: 2026-08-21*
