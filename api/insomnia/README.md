# Insomnia Collection: Assistant Backend API

Коллекция запросов для тестирования HTTP API бэкенда AI-ассистента.

## 📦 Как импортировать

1. Открой Insomnia
2. Нажми **стрелочку вниз** слева от имени workspace (или `Ctrl+Shift+I`)
3. Выбери **Import → From File**
4. Укажи файл `assistant_backend_collection.json`
5. Выбери **"Import as New Workspace"**

## 🌍 Environments

После импорта переключись на environment **Development (localhost)** в правом верхнем углу (dropdown).

### Переменные окружения (Base Environment):

| Переменная    | Значение (по умолчанию)              | Описание                          |
| ------------- | ------------------------------------ | --------------------------------- |
| `baseUrl`     | `http://localhost:8081`              | Базовый URL сервера               |
| `apiVersion`  | `v1`                                 | Версия API                        |
| `apiKey`      | `your-super-secret-api-key-123`      | API-ключ для авторизации          |
| `taskId`      | `1`                                  | ID задачи (для GET/PATCH/DELETE)  |
| `projectId`   | `1`                                  | ID проекта (для GET/PATCH/DELETE) |

## 📂 Структура коллекции

### 01. Health
- **Health check** — проверка работоспособности (без API-ключа)

### 02. Tasks
- List active tasks
- Filter by status
- Filter by project
- Overdue tasks
- Scheduled for date
- Get task by ID
- **Create task** ⭐
- Update task
- Delete task

### 03. Projects
- List active projects
- List all (with archived)
- List archived only
- **Create project** ⭐
- Get project by ID (со статистикой задач)
- Update project
- Archive project
- Unarchive project
- Delete project (запрещено при наличии задач)

## 🧪 Быстрый старт

1. Импортируй коллекцию
2. Переключись на **Development** environment
3. Запусти **Create project** → скопируй `id` из ответа
4. В Base Environment подставь `projectId = <полученный id>`
5. Запусти **Create task** (он использует `projectId` из переменной)
6. Скопируй `id` созданной задачи → подставь в `taskId`
7. Тестируй остальные запросы!

## ⚠️ Важно

- Все даты в API — **в формате ISO 8601, UTC** (например: `2026-08-21T14:30:00Z`)
- `DELETE /projects/<id>` вернёт `409 Conflict`, если у проекта есть привязанные задачи
- Статусы задач: `todo`, `in_progress`, `done`, `backlog`, `waiting`, `cancelled`
- Цвет проекта: hex-формат, например `#3498DB`
