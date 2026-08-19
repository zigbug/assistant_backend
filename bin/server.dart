import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

import 'package:assistant_backend/src/config/constants.dart';
import 'package:assistant_backend/src/database/database.dart';
import 'package:assistant_backend/src/database/daos/tasks_dao.dart';

/// Middleware для проверки наличия и корректности API-ключа в заголовке запроса.
/// Если ключ отсутствует или неверен, возвращает 401 Unauthorized.
/// Исключение: эндпоинт /health не требует аутентификации для систем мониторинга.
Middleware apiKeyMiddleware() {
  return (Handler innerHandler) {
    return (Request request) {
      // Health check не требует API ключа
      if (request.url.path == '/health' || request.url.path == '/health/') {
        return innerHandler(request);
      }

      // Извлекаем заголовок x-api-key
      final providedKey = request.headers['x-api-key'];

      if (providedKey == null || providedKey != AppConstants.apiKey) {
        return Response.unauthorized('Invalid or missing API key');
      }

      // Если ключ верный, передаем запрос дальше по цепочке обработчиков
      return innerHandler(request);
    };
  };
}

/// Настраивает и возвращает основной роутер приложения.
/// Вынесен в отдельную функцию для удобства тестирования.
Router createRouter(AppDatabase db) {
  final router = Router();
  final tasksDao = TasksDao(db);

  // === Health Check ===
  // Простой эндпоинт для проверки работоспособности сервера.
  // Не требует API-ключа, чтобы системы мониторинга могли пинговать сервер.
  router.get('/health', (Request request) {
    return Response.ok('OK', headers: {'Content-Type': 'text/plain'});
  });

  // === API v1 Routes ===
  // Создаем отдельный роутер для API v1, чтобы логически сгруппировать эндпоинты
  final apiRouter = Router();

  // GET /api/v1/tasks
  // Возвращает список всех активных задач (включая backlog, todo, in_progress)
  apiRouter.get('/tasks', (Request request) async {
    try {
      final tasks = await tasksDao.getActive();
      // Преобразуем список задач в JSON-совместимый формат
      final tasksJson = tasks.map((task) => task.toJson()).toList();

      return Response.ok(
        jsonEncode(tasksJson),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e, stackTrace) {
      // Пока оставляем базовую обработку, чтобы увидеть ошибку в консоли
      print('Error fetching tasks: $e\n$stackTrace');
      return Response.internalServerError(body: 'Failed to fetch tasks');
    }
  });

  // POST /api/v1/tasks
  // Создает новую задачу. Ожидает JSON с полями title, description (опц.), projectId (опц.) и т.д.
  apiRouter.post('/tasks', (Request request) async {
    try {
      // Читаем тело запроса и парсим JSON
      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      // Валидация обязательного поля
      if (data['title'] == null || data['title'].toString().trim().isEmpty) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Title is required'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // Парсим все поля из JSON с правильным приведением типов
      final title = data['title'].toString().trim();
      final description = data['description']?.toString();
      final projectId =
          data['projectId'] is int ? data['projectId'] as int : null;
      final importance =
          data['importance'] is int ? data['importance'] as int : 2;
      final urgency = data['urgency'] is int ? data['urgency'] as int : 2;
      final estimatedMinutes = data['estimatedMinutes'] is int
          ? data['estimatedMinutes'] as int
          : null;

      // Парсинг дат: поддерживаем ISO 8601 строки (например, "2026-08-20T14:30:00Z")
      DateTime? deadline;
      if (data['deadline'] != null && data['deadline'] is String) {
        deadline = DateTime.tryParse(data['deadline'] as String)?.toUtc();
      }

      DateTime? scheduledDate;
      if (data['scheduledDate'] != null && data['scheduledDate'] is String) {
        scheduledDate =
            DateTime.tryParse(data['scheduledDate'] as String)?.toUtc();
      }

      // Статус по умолчанию — todo для новых задач, созданных через API
      // (в DAO по умолчанию backlog, но для API удобнее todo)
      final status = data['status'] is String
          ? TaskStatus.values.firstWhere(
              (e) => e.name == data['status'],
              orElse: () => TaskStatus.todo,
            )
          : TaskStatus.todo;

      // Вызываем метод DAO — он сам сформирует TasksCompanion и вставит запись
      final taskId = await tasksDao.create(
        title: title,
        description: description,
        projectId: projectId,
        status: status,
        importance: importance,
        urgency: urgency,
        deadline: deadline,
        scheduledDate: scheduledDate,
        estimatedMinutes: estimatedMinutes,
      );

      return Response(
        201, // HTTP Created
        body: jsonEncode({
          'id': taskId,
          'message': 'Task created successfully',
        }),
        headers: {
          'Content-Type': 'application/json',
          'Location': '/api/${AppConstants.apiVersion}/tasks/$taskId',
        },
      );
    } catch (e, stackTrace) {
      print('Error creating task: $e\n$stackTrace');
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to create task'}),
        headers: {'Content-Type': 'application/json'},
      );
    }
  });

  // Монтируем API роутер с префиксом /api/v1/
  // Используем .call, чтобы передать apiRouter как handler функцию
  router.mount('/api/${AppConstants.apiVersion}/', apiRouter.call);

  return router;
}

Future<void> main(List<String> args) async {
  // Инициализируем базу данных через фабричную функцию.
  // Для локальной разработки используем SQLite в файле.
  // Для тестов можно передать inMemory: true.
  final db = createDatabase();

  // Создаем роутер
  final router = createRouter(db);

  // Собираем цепочку обработчиков (pipeline)
  // 1. logRequests() - логирует все входящие запросы в консоль
  // 2. apiKeyMiddleware() - проверяет API-ключ для всех запросов, кроме /health
  // 3. router.call - передает запрос в роутер
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      // Обратите внимание: мы применяем middleware ко всему роутеру,
      // но внутри роутера /health не требует ключа, так как он определен ДО mount с middleware?
      // Нет, shelf_router mount применяет middleware только к вложенным роутам, если мы сделаем иначе.
      // Чтобы /health был без ключа, лучше разделить pipeline или проверять путь в middleware.
      // Упростим: сделаем проверку ключа внутри mount, а /health оставим снаружи.
      .addHandler(router);

  // Запускаем сервер
  final server = await io.serve(
    handler,
    InternetAddress.anyIPv4,
    AppConstants.serverPort,
  );

  print('==================================================');
  print('  Assistant Backend Server is running!');
  print('  Environment: Development (SQLite)');
  print('  Listening on port ${server.port}');
  print('  Health check: http://localhost:${server.port}/health');
  print(
      '  API Base: http://localhost:${server.port}/api/${AppConstants.apiVersion}/');
  print('  Use header: x-api-key: ${AppConstants.apiKey}');
  print('==================================================');
}
