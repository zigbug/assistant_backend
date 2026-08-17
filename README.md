# Personal Assistant Backend

Серверная часть персонального ассистента для Senior Flutter-разработчика.

## Технологии

- **Язык**: Dart 3.5+
- **HTTP фреймворк**: shelf + shelf_router
- **База данных**: PostgreSQL через Drift
- **Деплой**: Docker + docker-compose

## Структура проекта

```
assistant_backend/
├── bin/
│   └── server.dart          # Точка входа HTTP сервера
├── lib/
│   ├── src/
│   │   ├── database/
│   │   │   ├── database.dart
│   │   │   ├── tables/
│   │   │   └── daos/
│   │   ├── routes/
│   │   ├── middleware/
│   │   └── models/
│   └── assistant_backend.dart
├── test/
├── docker-compose.yml
├── Dockerfile
└── Makefile
```

## Быстрый старт

```bash
# Установить зависимости
dart pub get

# Сгенерировать Drift код
dart run build_runner build --delete-conflicting-outputs

# Запустить сервер
dart run bin/server.dart
```

## Переменные окружения

Создай файл `.env`:

```env
PORT=8080
DB_HOST=localhost
DB_PORT=5432
DB_NAME=assistant
DB_USER=assistant
DB_PASSWORD=secret
API_KEY=your-secret-key
```

## API Endpoints

### Задачи
- `GET /api/v1/tasks` - Все незавершённые задачи
- `GET /api/v1/tasks/today` - Задачи на сегодня
- `POST /api/v1/tasks` - Создать задачу
- `PATCH /api/v1/tasks/{id}` - Обновить задачу
- `PATCH /api/v1/tasks/{id}/complete` - Завершить задачу

### Проекты
- `GET /api/v1/projects` - Все проекты
- `POST /api/v1/projects` - Создать проект

### Health
- `GET /health` - Health check

## Лицензия

MIT
