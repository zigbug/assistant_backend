import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

import 'package:assistant_backend/src/config/constants.dart';
import 'package:assistant_backend/src/database/database.dart';
import 'package:assistant_backend/src/database/daos/daily_plans_dao.dart';
import 'package:assistant_backend/src/database/daos/events_dao.dart';
import 'package:assistant_backend/src/database/daos/preferences_dao.dart';
import 'package:assistant_backend/src/database/daos/projects_dao.dart';
import 'package:assistant_backend/src/database/daos/tasks_dao.dart';
import 'package:assistant_backend/src/services/recurring_task_materializer.dart';
import 'package:assistant_backend/src/services/time_context.dart';

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
///
/// В каждый JSON-ответ встраивается текущий момент сервера (`serverTimeUtc`),
/// чтобы AI/MCP сразу понимал, «в каком времени» находится система.
/// Для объектных тел поле добавляется в body, для списков — в заголовок
/// `X-Server-Time-Utc`.
Response jsonResponse(
  int statusCode,
  Object? body, {
  Map<String, String>? additionalHeaders,
}) {
  final nowIso = DateTime.now().toUtc().toIso8601String();

  Object? payload = body;
  if (body is Map<String, dynamic>) {
    payload = {...body, 'serverTimeUtc': nowIso};
  }

  return Response(
    statusCode,
    body: jsonEncode(payload),
    headers: {
      'Content-Type': 'application/json',
      'X-Server-Time-Utc': nowIso,
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
Router createRouter(AppDatabase db,
    {RecurringTaskMaterializer? materializer}) {
  final router = Router();
  final tasksDao = TasksDao(db);
  final projectsDao = ProjectsDao(db);
  final preferencesDao = PreferencesDao(db);
  final eventsDao = EventsDao(db);
  final dailyPlansDao = DailyPlansDao(db);
  final recurringMaterializer =
      materializer ?? RecurringTaskMaterializer(db);

  // === Health Check ===
  // Простой эндпоинт для проверки работоспособности сервера.
  // Не требует API-ключа, чтобы системы мониторинга могли пинговать сервер.
  router.get('/health', (Request request) {
    return Response.ok('OK', headers: {'Content-Type': 'text/plain'});
  });

  // === API v1 Routes ===
  // Создаем отдельный роутер для API v1, чтобы логически сгруппировать эндпоинты
  final apiRouter = Router();

  // GET /api/v1/time
  // Возвращает текущее время сервера в UTC и в часовом поясе пользователя.
  // Нужен AI/MCP, чтобы понимать, какой сейчас момент в системе:
  //   - serverTimeUtc     — сейчас в UTC (ISO 8601)
  //   - serverTimeLocal   — сейчас в поясе пользователя (если известен offset)
  //   - timezone          — имя пояса из Preferences (по умолчанию Europe/Moscow)
  //   - utcOffsetMinutes  — смещение от UTC (null, если пояс не распознан;
  //                         можно задать явно через preference utc_offset_minutes)
  apiRouter.get('/time', (Request request) async {
    try {
      final tzName = await preferencesDao.get('timezone');
      final offsetStr = await preferencesDao.get('utc_offset_minutes');
      final explicitOffset = int.tryParse(offsetStr ?? '');
      final ctx = buildTimeContext(DateTime.now(), tzName,
          explicitOffsetMinutes: explicitOffset);
      return jsonResponse(200, ctx.toJson());
    } catch (e, stackTrace) {
      print('Error fetching time: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch time'});
    }
  });

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
        // По умолчанию — активные задачи (можно отфильтровать по статусу/проекту).
        // Шаблоны серий скрыты, если не передан ?include_templates=true.
        final includeTemplates = params['include_templates'] == 'true';
        tasks = await tasksDao.getActive(includeTemplates: includeTemplates);

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

      // === Повторяемость (серия задач) ===
      // recurrence: none|daily|weekly|monthly|yearly
      final recurrence = data['recurrence'] is String
          ? TaskRecurrence.values.firstWhere(
              (e) => e.name == data['recurrence'],
              orElse: () => TaskRecurrence.none,
            )
          : TaskRecurrence.none;
      // repeatInterval: каждые N дней/недель/месяцев/лет (>= 1)
      final repeatInterval =
          data['repeatInterval'] is int && (data['repeatInterval'] as int) >= 1
              ? data['repeatInterval'] as int
              : 1;
      // repeatEndDate: до какой даты продолжать серию (опционально, ISO 8601)
      DateTime? repeatEndDate;
      if (data['repeatEndDate'] != null && data['repeatEndDate'] is String) {
        repeatEndDate =
            DateTime.tryParse(data['repeatEndDate'] as String)?.toUtc();
      }
      // parentId: для экземпляров серии (обычно создаются материализатором)
      final int? parentId = data['parentId'] is int ? data['parentId'] as int : null;

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
        recurrence: recurrence,
        repeatInterval: repeatInterval,
        repeatEndDate: repeatEndDate,
        parentId: parentId,
      );

      // Если это шаблон серии — сразу материализуем ближайшие экземпляры,
      // чтобы задача появилась в плане уже с сегодняшнего дня.
      if (recurrence != TaskRecurrence.none) {
        await recurringMaterializer.materializeUpTo(
            now: DateTime.now().toUtc());
      }

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

      // === Обновление повторяемости (серия задач) ===
      TaskRecurrence? recurrence;
      if (data['recurrence'] is String) {
        try {
          recurrence = TaskRecurrence.values.firstWhere(
            (e) => e.name == data['recurrence'],
          );
        } catch (_) {
          return jsonResponse(400, {
            'error':
                'Invalid recurrence. Allowed: ${TaskRecurrence.values.map((e) => e.name).join(', ')}',
          });
        }
      }

      int? repeatInterval;
      if (data['repeatInterval'] is int) {
        final ri = data['repeatInterval'] as int;
        if (ri < 1) {
          return jsonResponse(400, {'error': 'repeatInterval must be >= 1'});
        }
        repeatInterval = ri;
      }

      // repeatEndDate: null — сбросить (серия бесконечная), строка — задать.
      DateTime? repeatEndDate;
      if (data.containsKey('repeatEndDate')) {
        if (data['repeatEndDate'] == null) {
          repeatEndDate = null;
        } else if (data['repeatEndDate'] is String) {
          repeatEndDate =
              DateTime.tryParse(data['repeatEndDate'] as String)?.toUtc();
          if (repeatEndDate == null) {
            return jsonResponse(400, {
              'error': 'Invalid repeatEndDate format. Use ISO 8601',
            });
          }
        }
      }

      final int? parentId =
          data['parentId'] is int ? data['parentId'] as int : null;

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
        recurrence: recurrence,
        repeatInterval: repeatInterval,
        repeatEndDate: data.containsKey('repeatEndDate')
            ? repeatEndDate
            : null,
        parentId: parentId,
      );

      if (updatedCount == 0) {
        return handleNotFound('Task', taskId);
      }

      // Если задача стала шаблоном серии — пересоздаём/дополняем экземпляры.
      if (recurrence != null && recurrence != TaskRecurrence.none) {
        await recurringMaterializer.materializeUpTo(
            now: DateTime.now().toUtc());
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
        'in_progress': tasksInProject
            .where((t) => t.status == TaskStatus.inProgress)
            .length,
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
  apiRouter.patch('/projects/<id>/unarchive',
      (Request request, String id) async {
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
          'error':
              'Cannot delete project: ${linkedTasks.length} task(s) are linked to it',
          'suggestion':
              'Delete or move the linked tasks first, or use PATCH /archive instead',
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
        return jsonResponse(
            400, {'error': 'Request body must be a non-empty object'});
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

  // ---------------------------------------------------------------------------
  // EVENTS ENDPOINTS
  // ---------------------------------------------------------------------------
  // События — это жёсткие блоки времени (встречи, созвоны, дни рождения).
  // В отличие от задач, события нельзя "выполнить" — они просто происходят.
  // Нужны для корректной генерации плана дня, чтобы AI не ставил задачи
  // во время уже запланированных встреч.

  // GET /api/v1/events
  // Возвращает список событий. По умолчанию — ближайшие 7 дней (upcoming).
  // Query-параметры:
  // - ?filter=today — только события на сегодня
  // - ?filter=upcoming&days=14 — будущие события (по умолчанию 7 дней)
  // - ?filter=all — все события (для синхронизации между устройствами)
  // Без параметра filter — эквивалентно ?filter=upcoming&days=7
  apiRouter.get('/events', (Request request) async {
    try {
      final params = request.url.queryParameters;
      final filter = params['filter'] ?? 'upcoming';

      List<Event> events;

      switch (filter) {
        case 'today':
          events = await eventsDao.getToday();
          break;
        case 'all':
          events = await eventsDao.getAll();
          break;
        case 'upcoming':
        default:
          final days = int.tryParse(params['days'] ?? '7') ?? 7;
          if (days < 1 || days > 365) {
            return jsonResponse(400, {
              'error': 'days parameter must be between 1 and 365',
            });
          }
          events = await eventsDao.getUpcoming(days: days);
          break;
      }

      final eventsJson = events.map((e) => e.toJson()).toList();
      return jsonResponse(200, eventsJson);
    } catch (e, stackTrace) {
      print('Error fetching events: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch events'});
    }
  });

  // POST /api/v1/events
  // Создает новое событие.
  // Ожидает JSON:
  // {
  //   "title": "Созвон с командой",        // обязательное (1-200 символов)
  //   "startsAt": "2026-08-22T14:00:00Z",  // обязательное (ISO 8601, UTC)
  //   "isAllDay": false,                    // опциональное, default false
  //   "recurrence": "weekly",               // опциональное: none|daily|weekly|monthly|yearly
  //   "remindMinutesBefore": 15,            // опциональное, default 30
  //   "location": "Zoom"                    // опциональное
  // }
  apiRouter.post('/events', (Request request) async {
    try {
      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      // === Валидация обязательных полей ===
      if (data['title'] == null || data['title'].toString().trim().isEmpty) {
        return jsonResponse(400, {'error': 'Title is required'});
      }

      if (data['startsAt'] == null || data['startsAt'] is! String) {
        return jsonResponse(400, {
          'error': 'startsAt is required and must be an ISO 8601 string',
        });
      }

      final startsAt = DateTime.tryParse(data['startsAt'] as String);
      if (startsAt == null) {
        return jsonResponse(400, {
          'error':
              'Invalid startsAt format. Use ISO 8601 (e.g. 2026-08-22T14:00:00Z)',
        });
      }

      // === Парсинг опциональных полей ===
      final title = data['title'].toString().trim();

      // Проверка длины title (согласно схеме: min 1, max 200)
      if (title.length > 200) {
        return jsonResponse(400, {
          'error': 'Title must be 200 characters or less',
        });
      }

      final isAllDay =
          data['isAllDay'] is bool ? data['isAllDay'] as bool : false;
      final location = data['location']?.toString();
      final remindMinutesBefore = data['remindMinutesBefore'] is int
          ? data['remindMinutesBefore'] as int
          : 30;

      // Валидация remindMinutesBefore
      if (remindMinutesBefore < 0) {
        return jsonResponse(400, {
          'error': 'remindMinutesBefore cannot be negative',
        });
      }

      // === Парсинг recurrence enum ===
      Recurrence recurrence = Recurrence.none;
      if (data['recurrence'] is String) {
        try {
          recurrence = Recurrence.values.firstWhere(
            (r) => r.name == data['recurrence'],
          );
        } catch (_) {
          return jsonResponse(400, {
            'error':
                'Invalid recurrence. Allowed: ${Recurrence.values.map((r) => r.name).join(', ')}',
          });
        }
      }

      // === Создание через DAO ===
      // Приводим startsAt к UTC согласно нашему архитектурному решению
      final eventId = await eventsDao.create(
        title: title,
        startsAt: startsAt.toUtc(),
        isAllDay: isAllDay,
        recurrence: recurrence,
        remindMinutesBefore: remindMinutesBefore,
        location: location,
      );

      return jsonResponse(
        201,
        {'id': eventId, 'message': 'Event created successfully'},
        additionalHeaders: {
          'Location': '/api/${AppConstants.apiVersion}/events/$eventId',
        },
      );
    } catch (e, stackTrace) {
      print('Error creating event: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to create event'});
    }
  });

  // GET /api/v1/events/<id>
  // Получение одного события по ID. Возвращает 404 если не найдено.
  apiRouter.get('/events/<id>', (Request request, String id) async {
    try {
      final eventId = int.tryParse(id);
      if (eventId == null) {
        return jsonResponse(400, {'error': 'Invalid event id'});
      }

      final event = await eventsDao.getById(eventId);
      if (event == null) {
        return handleNotFound('Event', eventId);
      }

      return jsonResponse(200, event.toJson());
    } catch (e, stackTrace) {
      print('Error fetching event $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch event'});
    }
  });

  // PATCH /api/v1/events/<id>
  // Частичное обновление события. Поддерживает любые поля из POST.
  // Возвращает обновленное событие или 404 если не найдено.
  apiRouter.patch('/events/<id>', (Request request, String id) async {
    try {
      final eventId = int.tryParse(id);
      if (eventId == null) {
        return jsonResponse(400, {'error': 'Invalid event id'});
      }

      // Проверяем существование события
      final existing = await eventsDao.getById(eventId);
      if (existing == null) {
        return handleNotFound('Event', eventId);
      }

      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      // === Парсинг полей для обновления ===
      String? title;
      if (data.containsKey('title')) {
        title = data['title']?.toString().trim();
        if (title != null && title.isEmpty) {
          return jsonResponse(400, {'error': 'Title cannot be empty'});
        }
        if (title != null && title.length > 200) {
          return jsonResponse(400, {
            'error': 'Title must be 200 characters or less',
          });
        }
      }

      DateTime? startsAt;
      if (data.containsKey('startsAt')) {
        if (data['startsAt'] == null) {
          return jsonResponse(400, {
            'error': 'startsAt cannot be null for existing event',
          });
        }
        if (data['startsAt'] is String) {
          startsAt = DateTime.tryParse(data['startsAt'] as String);
          if (startsAt == null) {
            return jsonResponse(400, {'error': 'Invalid startsAt format'});
          }
          startsAt = startsAt.toUtc();
        }
      }

      bool? isAllDay =
          data['isAllDay'] is bool ? data['isAllDay'] as bool : null;
      String? location = data['location']?.toString();
      int? remindMinutesBefore = data['remindMinutesBefore'] is int
          ? data['remindMinutesBefore'] as int
          : null;

      if (remindMinutesBefore != null && remindMinutesBefore < 0) {
        return jsonResponse(400, {
          'error': 'remindMinutesBefore cannot be negative',
        });
      }

      // === Парсинг recurrence enum ===
      Recurrence? recurrence;
      if (data['recurrence'] is String) {
        try {
          recurrence = Recurrence.values.firstWhere(
            (r) => r.name == data['recurrence'],
          );
        } catch (_) {
          return jsonResponse(400, {
            'error':
                'Invalid recurrence. Allowed: ${Recurrence.values.map((r) => r.name).join(', ')}',
          });
        }
      }

      final updatedCount = await eventsDao.updateEvent(
        eventId,
        title: title,
        startsAt: startsAt,
        isAllDay: isAllDay,
        recurrence: recurrence,
        remindMinutesBefore: remindMinutesBefore,
        location: location,
      );

      if (updatedCount == 0) {
        return handleNotFound('Event', eventId);
      }

      // Возвращаем обновленное событие
      final updated = await eventsDao.getById(eventId);
      return jsonResponse(200, updated?.toJson());
    } catch (e, stackTrace) {
      print('Error updating event $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to update event'});
    }
  });

  // DELETE /api/v1/events/<id>
  // Удаление события по ID. Возвращает 204 при успехе, 404 если не найдено.
  apiRouter.delete('/events/<id>', (Request request, String id) async {
    try {
      final eventId = int.tryParse(id);
      if (eventId == null) {
        return jsonResponse(400, {'error': 'Invalid event id'});
      }

      final deletedCount = await eventsDao.deleteById(eventId);
      if (deletedCount == 0) {
        return handleNotFound('Event', eventId);
      }

      return Response(204);
    } catch (e, stackTrace) {
      print('Error deleting event $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to delete event'});
    }
  });

  // ---------------------------------------------------------------------------
  // DAILY PLANS ENDPOINTS
  // ---------------------------------------------------------------------------
  // Планы дня — центральный элемент ассистента. Именно ради генерации плана
  // на день и создавался весь проект. Пока AI (Qwen) находится на стороне
  // десктопного клиента, эндпоинт /generate делает базовую эвристику:
  // собирает события на дату + задачи со scheduledDate + просроченные задачи.
  // В будущем MCP-сервер сможет делать более умную генерацию с учётом
  // preferences (peak_hours, lunch и т.д.) через эти же эндпоинты.

  // POST /api/v1/daily-plans/generate?date=YYYY-MM-DD
  // Генерирует (пересоздаёт) план на указанную дату.
  // Если date не указан — использует сегодня (UTC).
  // Логика:
  //   1. Создаёт/получает план на дату
  //   2. Удаляет все существующие элементы (идемпотентная генерация)
  //   3. Добавляет события на эту дату как элементы типа event
  //   4. Добавляет задачи с scheduledDate на эту дату как элементы типа task
  //   5. Добавляет просроченные задачи (catch-up) с пометкой OVERDUE в note
  // Возвращает план со всеми элементами.
  apiRouter.post('/daily-plans/generate', (Request request) async {
    try {
      final params = request.url.queryParameters;
      final dateStr = params['date'];

      // Парсим и нормализуем целевую дату (обнуляем время, приводим к UTC)
      DateTime targetDate;
      if (dateStr == null) {
        final now = DateTime.now().toUtc();
        targetDate = DateTime.utc(now.year, now.month, now.day);
      } else {
        final parsed = DateTime.tryParse(dateStr);
        if (parsed == null) {
          return jsonResponse(400, {
            'error': 'Invalid date format. Use ISO 8601 (e.g. 2026-08-21)',
          });
        }
        targetDate = DateTime.utc(parsed.year, parsed.month, parsed.day);
      }

      // Получаем или создаём план на дату
      final plan = await dailyPlansDao.getOrCreateForDate(targetDate);

      // Удаляем все существующие элементы плана — пересоздаём с нуля.
      // Это делает операцию идемпотентной: повторный вызов даёт тот же результат.
      final existingItems = await dailyPlansDao.getItems(plan.id);
      for (final item in existingItems) {
        await dailyPlansDao.deleteItemById(item.id);
      }

      // === Добавляем события на эту дату ===
      // События берём в диапазоне [targetDate, targetDate + 1 day)
      final targetEnd = targetDate.add(const Duration(days: 1));
      final events = await (db.select(db.events)
            ..where((e) =>
                e.startsAt.isBiggerOrEqualValue(targetDate) &
                e.startsAt.isSmallerThanValue(targetEnd)))
          .get();

      for (final event in events) {
        // Для событий на весь день endTime не задаём (null)
        // Для обычных событий — endTime = startsAt + 1 час (базовая эвристика)
        await dailyPlansDao.addItem(
          planId: plan.id,
          itemType: PlanItemType.event,
          refId: event.id,
          startTime: event.startsAt,
          endTime: event.isAllDay
              ? null
              : event.startsAt.add(const Duration(hours: 1)),
          note: event.title,
        );
      }

      // === Добавляем задачи, запланированные на эту дату ===
      final scheduledTasks = await tasksDao.getScheduledForDate(targetDate);
      final scheduledTaskIds = <int>{};
      for (final task in scheduledTasks) {
        scheduledTaskIds.add(task.id);
        final startTime = task.scheduledDate ?? targetDate;
        // Если есть оценка времени — вычисляем endTime
        final endTime = task.estimatedMinutes != null
            ? startTime.add(Duration(minutes: task.estimatedMinutes!))
            : null;
        await dailyPlansDao.addItem(
          planId: plan.id,
          itemType: PlanItemType.task,
          refId: task.id,
          startTime: startTime,
          endTime: endTime,
          note: task.title,
        );
      }

      // === Добавляем просроченные задачи (catch-up) ===
      // Берём задачи с deadline < сегодня, не включённые уже в план.
      // Это напоминает пользователю о забытых задачах.
      final overdueTasks = await tasksDao.getOverdue();
      for (final task in overdueTasks) {
        if (!scheduledTaskIds.contains(task.id)) {
          await dailyPlansDao.addItem(
            planId: plan.id,
            itemType: PlanItemType.task,
            refId: task.id,
            startTime: targetDate,
            endTime: null,
            note: 'OVERDUE: ${task.title}',
          );
        }
      }

      // Возвращаем полный план с элементами
      final result = await dailyPlansDao.getPlanWithItems(plan.id);
      return jsonResponse(200, {
        'plan': result.plan.toJson(),
        'items': result.items.map((i) => i.toJson()).toList(),
        'stats': {
          'events': events.length,
          'scheduledTasks': scheduledTasks.length,
          'overdueTasks': overdueTasks
              .where((t) => !scheduledTaskIds.contains(t.id))
              .length,
        },
      });
    } catch (e, stackTrace) {
      print('Error generating daily plan: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to generate daily plan'});
    }
  });

  // GET /api/v1/daily-plans/today
  // Получение плана на сегодня. Если плана нет — возвращает 404.
  // Для создания/генерации плана используй POST /generate.
  apiRouter.get('/daily-plans/today', (Request request) async {
    try {
      final plan = await dailyPlansDao.getToday();
      if (plan == null) {
        return jsonResponse(404, {
          'error':
              'No plan for today. Generate it with POST /daily-plans/generate',
        });
      }

      final result = await dailyPlansDao.getPlanWithItems(plan.id);
      return jsonResponse(200, {
        'plan': result.plan.toJson(),
        'items': result.items.map((i) => i.toJson()).toList(),
      });
    } catch (e, stackTrace) {
      print('Error fetching today plan: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch today plan'});
    }
  });

  // GET /api/v1/daily-plans/<date>
  // Получение плана на конкретную дату (формат YYYY-MM-DD, UTC).
  // Возвращает 404 если плана на эту дату нет.
  apiRouter.get('/daily-plans/<date>', (Request request, String date) async {
    try {
      final parsed = DateTime.tryParse(date);
      if (parsed == null) {
        return jsonResponse(400, {
          'error': 'Invalid date format. Use ISO 8601 (e.g. 2026-08-21)',
        });
      }
      final normalizedDate =
          DateTime.utc(parsed.year, parsed.month, parsed.day);

      // Ищем план по дате через прямой select (в DAO нет метода getByDate)
      final plan = await (db.select(db.dailyPlans)
            ..where((p) => p.date.equals(normalizedDate)))
          .getSingleOrNull();

      if (plan == null) {
        return jsonResponse(404, {
          'error': 'No plan for date $date',
        });
      }

      final result = await dailyPlansDao.getPlanWithItems(plan.id);
      return jsonResponse(200, {
        'plan': result.plan.toJson(),
        'items': result.items.map((i) => i.toJson()).toList(),
      });
    } catch (e, stackTrace) {
      print('Error fetching plan for $date: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch plan'});
    }
  });

  // GET /api/v1/daily-plans/id/<id>
  // Получение плана по его ID (вместе со всеми элементами).
  // Полезно, когда у MCP есть сохранённый ID плана и он хочет обновить его.
  apiRouter.get('/daily-plans/id/<id>', (Request request, String id) async {
    try {
      final planId = int.tryParse(id);
      if (planId == null) {
        return jsonResponse(400, {'error': 'Invalid plan id'});
      }

      final plan = await dailyPlansDao.getById(planId);
      if (plan == null) {
        return handleNotFound('DailyPlan', planId);
      }

      final result = await dailyPlansDao.getPlanWithItems(planId);
      return jsonResponse(200, {
        'plan': result.plan.toJson(),
        'items': result.items.map((i) => i.toJson()).toList(),
      });
    } catch (e, stackTrace) {
      print('Error fetching plan $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch plan'});
    }
  });

  // GET /api/v1/daily-plans/<id>/stats
  // Получение агрегированной статистики по плану дня.
  // Полезно для MCP и Flutter-клиента, чтобы одним запросом получать
  // полную картину дня: количество элементов по статусам, процент выполнения,
  // суммарное оценённое и фактически затраченное время.
  //
  // Пример ответа:
  // {
  //   "planId": 1,
  //   "date": "2026-08-21T00:00:00.000Z",
  //   "status": "confirmed",
  //   "totalItems": 8,
  //   "byStatus": { "planned": 3, "inProgress": 1, "done": 2, "skipped": 1, "moved": 0, "cancelled": 1 },
  //   "completedPercent": 25.0,
  //   "timeEstimatedMinutes": 480,
  //   "timeSpentMinutes": 120
  // }
  apiRouter.get('/daily-plans/<id>/stats', (Request request, String id) async {
    try {
      final planId = int.tryParse(id);
      if (planId == null) {
        return jsonResponse(400, {'error': 'Invalid plan id'});
      }

      final plan = await dailyPlansDao.getById(planId);
      if (plan == null) {
        return handleNotFound('DailyPlan', planId);
      }

      // Получаем все элементы плана
      final items = await dailyPlansDao.getItems(planId);

      // Считаем разбивку по статусам
      final byStatus = <String, int>{};
      for (final status in PlanItemStatus.values) {
        byStatus[status.name] = 0;
      }
      for (final item in items) {
        byStatus[item.status.name] = (byStatus[item.status.name] ?? 0) + 1;
      }

      // Считаем процент выполнения
      final totalItems = items.length;
      final doneCount = byStatus[PlanItemStatus.done.name] ?? 0;
      final completedPercent =
          totalItems > 0 ? (doneCount / totalItems * 100).roundToDouble() : 0.0;

      // Считаем оценённое время (сумма длительностей элементов с endTime)
      int timeEstimatedMinutes = 0;
      int timeSpentMinutes = 0;
      for (final item in items) {
        if (item.endTime != null) {
          final duration = item.endTime!.difference(item.startTime).inMinutes;
          timeEstimatedMinutes += duration;

          // В потраченное время включаем только выполненные элементы
          if (item.status == PlanItemStatus.done) {
            timeSpentMinutes += duration;
          }
        }
      }

      return jsonResponse(200, {
        'planId': plan.id,
        'date': plan.date.toIso8601String(),
        'status': plan.status.name,
        'totalItems': totalItems,
        'byStatus': byStatus,
        'completedPercent': completedPercent,
        'timeEstimatedMinutes': timeEstimatedMinutes,
        'timeSpentMinutes': timeSpentMinutes,
      });
    } catch (e, stackTrace) {
      print('Error fetching plan stats $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to fetch plan stats'});
    }
  });

  // PATCH /api/v1/daily-plans/<id>
  // Обновление метаданных плана: status (draft/confirmed/done) и/или aiComment.
  // Используется, когда:
  //   - Пользователь подтверждает план (draft → confirmed)
  //   - День завершился (confirmed → done)
  //   - AI оставляет комментарий/советы к плану (aiComment)
  apiRouter.patch('/daily-plans/<id>', (Request request, String id) async {
    try {
      final planId = int.tryParse(id);
      if (planId == null) {
        return jsonResponse(400, {'error': 'Invalid plan id'});
      }

      final existing = await dailyPlansDao.getById(planId);
      if (existing == null) {
        return handleNotFound('DailyPlan', planId);
      }

      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      // Обновляем статус если передан
      if (data['status'] is String) {
        try {
          final newStatus = PlanStatus.values.firstWhere(
            (s) => s.name == data['status'],
          );
          await dailyPlansDao.updatePlanStatus(planId, newStatus);
        } catch (_) {
          return jsonResponse(400, {
            'error':
                'Invalid status. Allowed: ${PlanStatus.values.map((s) => s.name).join(', ')}',
          });
        }
      }

      // Обновляем AI-комментарий если передан
      if (data['aiComment'] is String) {
        await dailyPlansDao.updateAiComment(
            planId, data['aiComment'] as String);
      }

      final updated = await dailyPlansDao.getById(planId);
      return jsonResponse(200, updated?.toJson());
    } catch (e, stackTrace) {
      print('Error updating plan $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to update plan'});
    }
  });

  // DELETE /api/v1/daily-plans/<id>
  // Удаляет план и все его элементы (каскадно).
  // Используется для "сброса" плана перед регенерацией или при отмене.
  apiRouter.delete('/daily-plans/<id>', (Request request, String id) async {
    try {
      final planId = int.tryParse(id);
      if (planId == null) {
        return jsonResponse(400, {'error': 'Invalid plan id'});
      }

      final deletedCount = await dailyPlansDao.deletePlanById(planId);
      if (deletedCount == 0) {
        return handleNotFound('DailyPlan', planId);
      }

      return Response(204);
    } catch (e, stackTrace) {
      print('Error deleting plan $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to delete plan'});
    }
  });

  // POST /api/v1/daily-plans/<id>/items
  // Добавляет элемент в план вручную. Используется для:
  //   - Создания пользовательских перерывов (breakSlot)
  //   - Привязки дополнительных задач к плану
  //   - Привязки привычек (когда появится v2)
  // Ожидает JSON:
  // {
  //   "itemType": "task|event|habit|breakSlot",
  //   "refId": 123,                  // опционально для task/event/habit
  //   "startTime": "2026-08-21T14:00:00Z",
  //   "endTime": "2026-08-21T15:00:00Z",  // опционально
  //   "note": "Обед"                  // опционально
  // }
  apiRouter.post('/daily-plans/<id>/items', (Request request, String id) async {
    try {
      final planId = int.tryParse(id);
      if (planId == null) {
        return jsonResponse(400, {'error': 'Invalid plan id'});
      }

      // Проверяем существование плана
      final existingPlan = await dailyPlansDao.getById(planId);
      if (existingPlan == null) {
        return handleNotFound('DailyPlan', planId);
      }

      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      // === Валидация обязательных полей ===
      if (data['itemType'] is! String) {
        return jsonResponse(400, {'error': 'itemType is required'});
      }
      PlanItemType itemType;
      try {
        itemType = PlanItemType.values.firstWhere(
          (t) => t.name == data['itemType'],
        );
      } catch (_) {
        return jsonResponse(400, {
          'error':
              'Invalid itemType. Allowed: ${PlanItemType.values.map((t) => t.name).join(', ')}',
        });
      }

      if (data['startTime'] is! String) {
        return jsonResponse(400, {'error': 'startTime is required (ISO 8601)'});
      }
      final startTime = DateTime.tryParse(data['startTime'] as String);
      if (startTime == null) {
        return jsonResponse(400, {'error': 'Invalid startTime format'});
      }

      // === Опциональные поля ===
      final int? refId = data['refId'] is int ? data['refId'] as int : null;
      final String? note = data['note']?.toString();

      DateTime? endTime;
      if (data['endTime'] is String) {
        endTime = DateTime.tryParse(data['endTime'] as String);
        if (endTime == null) {
          return jsonResponse(400, {'error': 'Invalid endTime format'});
        }
      }

      // Создаём элемент через DAO
      final itemId = await dailyPlansDao.addItem(
        planId: planId,
        itemType: itemType,
        refId: refId,
        startTime: startTime.toUtc(),
        endTime: endTime?.toUtc(),
        note: note,
      );

      return jsonResponse(
        201,
        {'id': itemId, 'message': 'Plan item added successfully'},
        additionalHeaders: {
          'Location':
              '/api/${AppConstants.apiVersion}/daily-plans/items/$itemId',
        },
      );
    } catch (e, stackTrace) {
      print('Error adding plan item: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to add plan item'});
    }
  });

  // PATCH /api/v1/daily-plans/items/<id>
  // Обновление элемента плана. Поддерживает:
  //   - status: planned|done|skipped|moved
  //   - startTime, endTime (для reschedule)
  //   - note (заметка/причина изменения)
  // Главный use case: пользователь отмечает выполнение блока в течение дня.
  apiRouter.patch('/daily-plans/items/<id>',
      (Request request, String id) async {
    try {
      final itemId = int.tryParse(id);
      if (itemId == null) {
        return jsonResponse(400, {'error': 'Invalid item id'});
      }

      final payload = await request.readAsString();
      final data = jsonDecode(payload) as Map<String, dynamic>;

      // === Обновление статуса (самое частое действие) ===
      if (data['status'] is String) {
        try {
          final newStatus = PlanItemStatus.values.firstWhere(
            (s) => s.name == data['status'],
          );
          final note = data['note']?.toString();
          final updatedCount = await dailyPlansDao.updateItemStatus(
            itemId,
            newStatus,
            note: note,
          );
          if (updatedCount == 0) {
            return handleNotFound('DailyPlanItem', itemId);
          }
        } catch (_) {
          return jsonResponse(400, {
            'error':
                'Invalid status. Allowed: ${PlanItemStatus.values.map((s) => s.name).join(', ')}',
          });
        }
      }

      // === Перенос элемента (reschedule) ===
      if (data['startTime'] is String && data['endTime'] is String) {
        final newStart = DateTime.tryParse(data['startTime'] as String);
        final newEnd = DateTime.tryParse(data['endTime'] as String);
        if (newStart == null || newEnd == null) {
          return jsonResponse(400, {
            'error': 'Invalid startTime/endTime format',
          });
        }
        await dailyPlansDao.rescheduleItem(
            itemId, newStart.toUtc(), newEnd.toUtc());
      }

      // Возвращаем обновлённый элемент (через select, т.к. DAO не имеет getById для item)
      final updatedItem = await (db.select(db.dailyPlanItems)
            ..where((i) => i.id.equals(itemId)))
          .getSingleOrNull();

      if (updatedItem == null) {
        return handleNotFound('DailyPlanItem', itemId);
      }

      return jsonResponse(200, updatedItem.toJson());
    } catch (e, stackTrace) {
      print('Error updating plan item $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to update plan item'});
    }
  });

  // DELETE /api/v1/daily-plans/items/<id>
  // Удаление элемента плана. Используется для удаления перерыва или отмены задачи.
  apiRouter.delete('/daily-plans/items/<id>',
      (Request request, String id) async {
    try {
      final itemId = int.tryParse(id);
      if (itemId == null) {
        return jsonResponse(400, {'error': 'Invalid item id'});
      }

      final deletedCount = await dailyPlansDao.deleteItemById(itemId);
      if (deletedCount == 0) {
        return handleNotFound('DailyPlanItem', itemId);
      }

      return Response(204);
    } catch (e, stackTrace) {
      print('Error deleting plan item $id: $e\n$stackTrace');
      return jsonResponse(500, {'error': 'Failed to delete plan item'});
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

  // Материализатор повторяющихся задач.
  final materializer = RecurringTaskMaterializer(db);

  // Первичная материализация при старте (идемпотентна) —
  // чтобы серии, созданные во время простоя сервера, появились сразу.
  try {
    final initial = await materializer.materializeUpTo(
        now: DateTime.now().toUtc());
    print(
        'Recurring tasks: ${initial.created} instance(s) materialized from ${initial.templatesProcessed} template(s)');
  } catch (e, stackTrace) {
    print('Error materializing recurring tasks at startup: $e\n$stackTrace');
  }

  // Планировщик: каждые 6 часов проверяем и материализуем новые экземпляры.
  Timer.periodic(const Duration(hours: 6), (_) async {
    try {
      await materializer.materializeUpTo(now: DateTime.now().toUtc());
    } catch (e, stackTrace) {
      print('Error in recurring tasks scheduler: $e\n$stackTrace');
    }
  });

  // Создаем роутер с эндпоинтами
  final router = createRouter(db, materializer: materializer);

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
  // API-ключ намеренно не печатаем — он утёк бы в docker logs.
  print('  Auth: заголовок x-api-key (значение в переменной API_KEY)');
  print('==================================================');
}
