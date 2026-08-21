import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

import 'package:assistant_backend/src/config/constants.dart';
import 'package:assistant_backend/src/database/database.dart';
import 'package:assistant_backend/src/database/daos/preferences_dao.dart';
import 'package:assistant_backend/src/database/daos/projects_dao.dart';
import 'package:assistant_backend/src/database/daos/tasks_dao.dart';

/// Middleware для проверки наличия и корректности API-ключа в заголовке запроса.
/// Если ключ отсутствует или неверен, возвращает 401 Unauthorized.
/// Исключение: эндпоинт /health не требует аутентификации для систем мониторинга.
Middleware apiKeyMiddleware() {
  return (Handler innerHandler) {
    return (Request request) {
      // Health check не требует API ключа — проверяем полный путь URL
      final path = request.url.path;
      if (path == 'health' || path == 'health/') {
        return innerHandler(request);
      }

      // Извлекаем заголовок x-api-key
      final providedKey = request.headers['x-api-key'];

      if (providedKey == null || providedKey != AppConstants.apiKey) {
        return Response.unauthorized(
          jsonEncode({'error': 'Invalid or missing API key'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      // Если ключ верный, передаем запрос дальше по цепочке обработчиков
      return innerHandler(request);
    };
  };
}

/// Вспомогательная функция для создания JSON-ответа с нужным Content-Type.
Response jsonResponse(
  int statusCode,
  Object? body, {
  Map<String, String>? additionalHeaders,
}) {
  return Response(
    statusCode,
    body: jsonEncode(body),
    headers: {
      'Content-Type': 'application/json',
      ...?additionalHeaders,
    },
  );
}

/// Вспомогательная функция для обработки ошибок DAO.
/// Возвращает 404 если запись не найдена (возвращает 0 при update/delete).
Response handleNotFound(String entityName, int id) {
  return jsonResponse(404, {
    'error': '$entityName with id=$id not found',
  });
}

/// Настраивает и возвращает основной роутер приложения.
/// Вынесен в отдельную функцию для удобства тестирования.
Router createRouter(AppDatabase db) {
  final router = Router();
  final tasksDao = TasksDao(db);
  final projectsDao = ProjectsDao(db);
  final preferencesDao = PreferencesDao(db);

  // === Health Check ===
  // Простой эндпоинт для проверки работоспособности сервера.
  // Не требует API-ключа, чтобы системы мониторинга могли пинговать сервер.
  router.get('/health', (Request request) {
    return Response.ok('OK', headers: {'Content-Type': 'text/plain'});
  });

  // === API v1 Routes ===
  // Создаем отдельный роутер для API v1, чтобы логически сгруппировать эндпоинты
  final apiRouter = Router();

  // ---------------------------------------------------------------------------
  // TASKS ENDPOINTS
  // ---------------------------------------------------------------------------

  // GET /api/v1/tasks
  // Возвращает список задач. Поддерживает фильтрацию через query-параметры:
  // - ?status=todo|in_progress|done|backlog|waiting|cancelled
  // - ?project_id=1
  // - ?overdue=true (просроченные задачи)
  // - ?scheduled=2026-08-20 (задачи на конкретную дату)
  apiRouter.get('/tasks', (Request request) async {
    try {
      final params = request.url.queryParameters;
      List<Task> tasks;

      if (params['overdue'] == 'true') {
        // Просроченные задачи
        tasks = await tasksDao.getOverdue();
      } else if (params.containsKey('scheduled')) {
        // Задачи на конкретную дату (ISO 8601)
        final dateStr = params['scheduled'];
        if (dateStr == null) {
          return jsonResponse(400, {'error': 'scheduled parameter is empty'});
        }
        final date = DateTime.tryParse(dateStr);
        if (date == null) {
          return jsonResponse(400, {
            'error': 'Invalid date format. Use ISO 8601 (e.g. 2026-08-20)',
          });
        }
        tasks = await tasksDao.getScheduledForDate(date.toUtc());
      } else {
        // По умолчанию — активные задачи (можно отфильтровать по статусу/проекту)
        tasks = await tasksDao.getActive();

        // Дополнительная фильтрация по статусу
        final statusFilter = params['status'];
        if (statusFilter != null) {
          tasks = tasks.where((t) => t.status.name == statusFilter).toList();
        }

        // Дополнительная фильтрация по проекту
        final projectIdFilter = params['project_id'];
        if (projectIdFilter != null) {
          final projectId = int.tryParse(projectIdFilter);
          if (projectId != null) {
            tasks = tasks.where((t) => t.projectId == projectId).toList();
          }
        }
      }

      final tasksJson = tasks.map((task) => task.toJson()).toList();
      return jsonResponse(200, tasksJson);
    } catch (e, stackTrace) {
      print('Error fetching tasks: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch tasks'});
    }
  });

  // POST /api/v1/tasks
  // Создает новую задачу. Ожидает JSON с полями title, description (опц.), projectId (опц.) и т.д.
  apiRouter.post('/tasks', (Request request) async {
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      // Валидация обязательного поля
      if (data['title'] == null || data['title'].toString().trim().isEmpty) {
        return jsonResponse(400, {'error': 'Title is required'});
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

      return jsonResponse(
        201,
        {'id': taskId, 'message': 'Task created successfully'},
        additionalHeaders: {
          'Location': '/api/${AppConstants.apiVersion}/tasks/$taskId',
        },
      );
    } catch (e, stackTrace) {
      print('Error creating task: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to create task'});
    }
  });

  // GET /api/v1/tasks/<id>
  // Получение одной задачи по её ID.
  // Возвращает 404 если задача не найдена.
  apiRouter.get('/tasks/<id>', (Request request, String id) async {
    try {
      final taskId = int.tryParse(id);
      if (taskId == null) {
        return jsonResponse(400, {'error': 'Invalid task id'});
      }

      final task = await tasksDao.getById(taskId);
      if (task == null) {
        return handleNotFound('Task', taskId);
      }

      return jsonResponse(200, task.toJson());
    } catch (e, stackTrace) {
      print('Error fetching task $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch task'});
    }
  });

  // PATCH /api/v1/tasks/<id>
  // Частичное обновление задачи. Поддерживает обновление любых полей:
  // - title, description, projectId
  // - status (todo, in_progress, done, backlog, waiting, cancelled)
  // - importance, urgency (матрица Эйзенхауэра, 1-5)
  // - deadline, scheduledDate (ISO 8601, UTC)
  // - estimatedMinutes, actualMinutes
  // Возвращает обновленную задачу. 404 если задача не найдена.
  apiRouter.patch('/tasks/<id>', (Request request, String id) async {
    try {
      final taskId = int.tryParse(id);
      if (taskId == null) {
        return jsonResponse(400, {'error': 'Invalid task id'});
      }

      // Проверяем существование задачи
      final existing = await tasksDao.getById(taskId);
      if (existing == null) {
        return handleNotFound('Task', taskId);
      }

      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      // Парсим опциональные поля для обновления
      final String? title = data['title']?.toString().trim();
      final String? description = data['description']?.toString();
      final int? projectId =
          data['projectId'] is int ? data['projectId'] as int : null;
      final int? importance =
          data['importance'] is int ? data['importance'] as int : null;
      final int? urgency =
          data['urgency'] is int ? data['urgency'] as int : null;
      final int? estimatedMinutes = data['estimatedMinutes'] is int
          ? data['estimatedMinutes'] as int
          : null;
      final int? actualMinutes =
          data['actualMinutes'] is int ? data['actualMinutes'] as int : null;

      // Парсинг дат
      DateTime? deadline;
      if (data.containsKey('deadline')) {
        if (data['deadline'] == null) {
          // Явный null — сбрасываем deadline
          deadline = null;
        } else if (data['deadline'] is String) {
          deadline = DateTime.tryParse(data['deadline'] as String)?.toUtc();
          if (deadline == null) {
            return jsonResponse(400, {
              'error': 'Invalid deadline format. Use ISO 8601',
            });
          }
        }
      }

      DateTime? scheduledDate;
      if (data.containsKey('scheduledDate')) {
        if (data['scheduledDate'] == null) {
          scheduledDate = null;
        } else if (data['scheduledDate'] is String) {
          scheduledDate =
              DateTime.tryParse(data['scheduledDate'] as String)?.toUtc();
          if (scheduledDate == null) {
            return jsonResponse(400, {
              'error': 'Invalid scheduledDate format. Use ISO 8601',
            });
          }
        }
      }

      // Парсинг статуса: ищем по имени, если не найдено — возвращаем 400
      TaskStatus? status;
      if (data['status'] is String) {
        try {
          status = TaskStatus.values.firstWhere(
            (e) => e.name == data['status'],
          );
        } catch (_) {
          return jsonResponse(400, {
            'error':
                'Invalid status. Allowed: ${TaskStatus.values.map((e) => e.name).join(', ')}',
          });
        }
      }

      // Вызываем DAO для обновления
      final updatedCount = await tasksDao.updateTask(
        taskId,
        title: title,
        description: description,
        projectId: data.containsKey('projectId') ? projectId : null,
        status: status,
        importance: importance,
        urgency: urgency,
        deadline: deadline,
        scheduledDate: scheduledDate,
        estimatedMinutes: estimatedMinutes,
        actualMinutes: actualMinutes,
      );

      if (updatedCount == 0) {
        return handleNotFound('Task', taskId);
      }

      // Возвращаем обновленную задачу
      final updatedTask = await tasksDao.getById(taskId);
      return jsonResponse(200, updatedTask?.toJson());
    } catch (e, stackTrace) {
      print('Error updating task $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to update task'});
    }
  });

  // DELETE /api/v1/tasks/<id>
  // Удаление задачи по ID. Возвращает 204 No Content при успехе, 404 если не найдена.
  // ⚠️ Осторожно: физическое удаление из БД. В будущем можно заменить на soft delete.
  apiRouter.delete('/tasks/<id>', (Request request, String id) async {
    try {
      final taskId = int.tryParse(id);
      if (taskId == null) {
        return jsonResponse(400, {'error': 'Invalid task id'});
      }

      final deletedCount = await tasksDao.deleteById(taskId);
      if (deletedCount == 0) {
        return handleNotFound('Task', taskId);
      }

      // 204 No Content — стандартный ответ на успешное удаление
      return Response(204);
    } catch (e, stackTrace) {
      print('Error deleting task $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to delete task'});
    }
  });

  // ---------------------------------------------------------------------------
  // PROJECTS ENDPOINTS
  // ---------------------------------------------------------------------------

  // GET /api/v1/projects
  // Возвращает список проектов.
  // Query-параметры:
  // - ?archived=true — показать только архивированные
  // - ?include_archived=true — показать все (активные + архивные)
  // По умолчанию возвращает только активные проекты.
  apiRouter.get('/projects', (Request request) async {
    try {
      final params = request.url.queryParameters;

      List<Project> projects;
      if (params['archived'] == 'true') {
        // Только архивированные: получаем все и фильтруем вручную
        // (в DAO нет отдельного метода, но для простого случая достаточно)
        final all = await projectsDao.getAllActive().then((_) async {
          // Получаем все через select — пока используем фильтр на клиенте
          return await (db.select(db.projects)).get();
        });
        projects = all.where((p) => p.isArchived).toList();
      } else if (params['include_archived'] == 'true') {
        // Все проекты (активные + архивные)
        projects = await (db.select(db.projects)).get();
      } else {
        // По умолчанию — только активные
        projects = await projectsDao.getAllActive();
      }

      final projectsJson = projects.map((p) => p.toJson()).toList();
      return jsonResponse(200, projectsJson);
    } catch (e, stackTrace) {
      print('Error fetching projects: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch projects'});
    }
  });

  // POST /api/v1/projects
  // Создает новый проект.
  // Ожидает JSON: { "name": "Работа", "color": "#FF5733" }
  // name — обязательное поле (1-100 символов).
  // color — опциональный hex-цвет для визуализации в UI.
  apiRouter.post('/projects', (Request request) async {
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      // Валидация обязательного поля
      if (data['name'] == null || data['name'].toString().trim().isEmpty) {
        return jsonResponse(400, {'error': 'Name is required'});
      }

      final name = data['name'].toString().trim();

      // Валидация длины
      if (name.length > 100) {
        return jsonResponse(400, {
          'error': 'Name must be 100 characters or less',
        });
      }

      // Опциональный цвет
      final String? color = data['color']?.toString();

      // Валидация формата hex-цвета (если передан)
      if (color != null && color.isNotEmpty) {
        final hexRegex = RegExp(r'^#[0-9A-Fa-f]{6}$');
        if (!hexRegex.hasMatch(color)) {
          return jsonResponse(400, {
            'error': 'Invalid color format. Use hex format like #FF5733',
          });
        }
      }

      final projectId = await projectsDao.create(name, color: color);

      return jsonResponse(
        201,
        {'id': projectId, 'message': 'Project created successfully'},
        additionalHeaders: {
          'Location': '/api/${AppConstants.apiVersion}/projects/$projectId',
        },
      );
    } catch (e, stackTrace) {
      print('Error creating project: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to create project'});
    }
  });

  // GET /api/v1/projects/<id>
  // Получение одного проекта по ID.
  // В будущем можно расширить, чтобы возвращать также список задач этого проекта.
  apiRouter.get('/projects/<id>', (Request request, String id) async {
    try {
      final projectId = int.tryParse(id);
      if (projectId == null) {
        return jsonResponse(400, {'error': 'Invalid project id'});
      }

      final project = await projectsDao.getById(projectId);
      if (project == null) {
        return handleNotFound('Project', projectId);
      }

      // Опционально: получаем количество задач этого проекта
      final tasksInProject = await (db.select(db.tasks)
            ..where((t) => t.projectId.equals(projectId)))
          .get();

      final result = project.toJson();
      result['taskCount'] = tasksInProject.length;
      // Добавляем краткую статистику по статусам
      result['taskStats'] = {
        'total': tasksInProject.length,
        'done': tasksInProject.where((t) => t.status == TaskStatus.done).length,
        'in_progress':
            tasksInProject.where((t) => t.status == TaskStatus.inProgress).length,
        'todo': tasksInProject.where((t) => t.status == TaskStatus.todo).length,
      };

      return jsonResponse(200, result);
    } catch (e, stackTrace) {
      print('Error fetching project $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch project'});
    }
  });

  // PATCH /api/v1/projects/<id>
  // Частичное обновление проекта.
  // Поддерживает поля: name (1-100 символов), color (hex).
  apiRouter.patch('/projects/<id>', (Request request, String id) async {
    try {
      final projectId = int.tryParse(id);
      if (projectId == null) {
        return jsonResponse(400, {'error': 'Invalid project id'});
      }

      // Проверяем существование проекта
      final existing = await projectsDao.getById(projectId);
      if (existing == null) {
        return handleNotFound('Project', projectId);
      }

      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      String? name;
      if (data.containsKey('name')) {
        name = data['name']?.toString().trim();
        if (name != null && name.isEmpty) {
          return jsonResponse(400, {'error': 'Name cannot be empty'});
        }
        if (name != null && name.length > 100) {
          return jsonResponse(400, {
            'error': 'Name must be 100 characters or less',
          });
        }
      }

      String? color;
      if (data.containsKey('color')) {
        color = data['color']?.toString();
        if (color != null && color.isNotEmpty) {
          final hexRegex = RegExp(r'^#[0-9A-Fa-f]{6}$');
          if (!hexRegex.hasMatch(color)) {
            return jsonResponse(400, {
              'error': 'Invalid color format. Use hex format like #FF5733',
            });
          }
        }
      }

      final updatedCount = await projectsDao.updateProject(
        projectId,
        name: name,
        color: color,
      );

      if (updatedCount == 0) {
        return handleNotFound('Project', projectId);
      }

      // Возвращаем обновлённый проект
      final updated = await projectsDao.getById(projectId);
      return jsonResponse(200, updated?.toJson());
    } catch (e, stackTrace) {
      print('Error updating project $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to update project'});
    }
  });

  // PATCH /api/v1/projects/<id>/archive
  // Архивирует проект. Задачи проекта остаются, но не отображаются
  // в активных списках. Можно использовать для "заморозки" проекта.
  apiRouter.patch('/projects/<id>/archive', (Request request, String id) async {
    try {
      final projectId = int.tryParse(id);
      if (projectId == null) {
        return jsonResponse(400, {'error': 'Invalid project id'});
      }

      final updatedCount = await projectsDao.archive(projectId);
      if (updatedCount == 0) {
        return handleNotFound('Project', projectId);
      }

      final updated = await projectsDao.getById(projectId);
      return jsonResponse(200, updated?.toJson());
    } catch (e, stackTrace) {
      print('Error archiving project $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to archive project'});
    }
  });

  // PATCH /api/v1/projects/<id>/unarchive
  // Восстанавливает проект из архива.
  apiRouter.patch(
      '/projects/<id>/unarchive', (Request request, String id) async {
    try {
      final projectId = int.tryParse(id);
      if (projectId == null) {
        return jsonResponse(400, {'error': 'Invalid project id'});
      }

      final updatedCount = await projectsDao.unarchive(projectId);
      if (updatedCount == 0) {
        return handleNotFound('Project', projectId);
      }

      final updated = await projectsDao.getById(projectId);
      return jsonResponse(200, updated?.toJson());
    } catch (e, stackTrace) {
      print('Error unarchiving project $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to unarchive project'});
    }
  });

  // DELETE /api/v1/projects/<id>
  // Удаляет проект.
  // ⚠️ ВАЖНО: удаление запрещено, если к проекту привязаны задачи,
  // чтобы не потерять данные. Сначала нужно удалить/переместить все задачи,
  // либо использовать archive вместо delete.
  apiRouter.delete('/projects/<id>', (Request request, String id) async {
    try {
      final projectId = int.tryParse(id);
      if (projectId == null) {
        return jsonResponse(400, {'error': 'Invalid project id'});
      }

      // Проверяем, есть ли задачи, привязанные к этому проекту
      final linkedTasks = await (db.select(db.tasks)
            ..where((t) => t.projectId.equals(projectId)))
          .get();

      if (linkedTasks.isNotEmpty) {
        return jsonResponse(409, {
          'error': 'Cannot delete project: ${linkedTasks.length} task(s) are linked to it',
          'suggestion': 'Delete or move the linked tasks first, or use PATCH /archive instead',
          'linkedTaskCount': linkedTasks.length,
        });
      }

      final deletedCount = await projectsDao.deleteById(projectId);
      if (deletedCount == 0) {
        return handleNotFound('Project', projectId);
      }

      return Response(204);
    } catch (e, stackTrace) {
      print('Error deleting project $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to delete project'});
    }
  });

  // ---------------------------------------------------------------------------
  // PREFERENCES ENDPOINTS
  // ---------------------------------------------------------------------------

  // GET /api/v1/preferences
  // Возвращает все настройки пользователя как JSON-объект (Map<String, String>).
  // Используется MCP/Qwen для получения контекста перед генерацией плана дня.
  apiRouter.get('/preferences', (Request request) async {
    try {
      final allPrefs = await preferencesDao.getAll();
      return jsonResponse(200, allPrefs);
    } catch (e, stackTrace) {
      print('Error fetching preferences: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch preferences'});
    }
  });

  // PATCH /api/v1/preferences
  // Обновляет несколько настроек одновременно.
  // Ожидает JSON-объект с парами key-value, например:
  //   { "work_start": "08:30", "peak_hours": "morning" }
  // Возвращает обновлённый набор всех настроек.
  apiRouter.patch('/preferences', (Request request) async {
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      if (data.isEmpty) {
        return jsonResponse(400, {'error': 'Request body must be a non-empty object'});
      }

      // Валидация: все ключи и значения должны быть строками
      final Map<String, String> updates = {};
      for (final entry in data.entries) {
        if (entry.key.isEmpty || entry.key.length > 100) {
          return jsonResponse(400, {
            'error': 'Invalid key "${entry.key}": must be 1-100 characters',
          });
        }
        if (entry.value == null) {
          return jsonResponse(400, {
            'error': 'Value for key "${entry.key}" cannot be null',
          });
        }
        updates[entry.key] = entry.value.toString();
      }

      await preferencesDao.setMany(updates);

      // Возвращаем полный набор настроек после обновления
      final allPrefs = await preferencesDao.getAll();
      return jsonResponse(200, allPrefs);
    } catch (e, stackTrace) {
      print('Error updating preferences: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to update preferences'});
    }
  });

  // GET /api/v1/preferences/<key>
  // Получает одну настройку по ключу. Возвращает 404 если ключ не существует.
  apiRouter.get('/preferences/<key>', (Request request, String key) async {
    try {
      final value = await preferencesDao.get(key);
      if (value == null) {
        return jsonResponse(404, {
          'error': 'Preference "$key" not found',
        });
      }
      return jsonResponse(200, {'key': key, 'value': value});
    } catch (e, stackTrace) {
      print('Error fetching preference $key: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch preference'});
    }
  });

  // PUT /api/v1/preferences/<key>
  // Создаёт или обновляет одну настройку по ключу.
  // Ожидает JSON: { "value": "..." }
  apiRouter.put('/preferences/<key>', (Request request, String key) async {
    try {
      if (key.isEmpty || key.length > 100) {
        return jsonResponse(400, {
          'error': 'Invalid key: must be 1-100 characters',
        });
      }

      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      if (!data.containsKey('value') || data['value'] == null) {
        return jsonResponse(400, {
          'error': 'Body must contain "value" field',
        });
      }

      final value = data['value'].toString();
      await preferencesDao.set(key, value);

      return jsonResponse(200, {'key': key, 'value': value});
    } catch (e, stackTrace) {
      print('Error setting preference $key: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to set preference'});
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

  // Создаем роутер с эндпоинтами
  final router = createRouter(db);

  // Собираем цепочку обработчиков (pipeline)
  // 1. logRequests() - логирует все входящие запросы в консоль
  // 2. apiKeyMiddleware() - проверяет API-ключ (кроме /health)
  // 3. router.call - передает запрос в роутер
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(apiKeyMiddleware())
      .addHandler(router.call);

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
