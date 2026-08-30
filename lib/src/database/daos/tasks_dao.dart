import 'package:drift/drift.dart';

import '../database.dart';

part 'tasks_dao.g.dart';

/// DAO для работы с задачами
@DriftAccessor(tables: [Tasks, Projects])
class TasksDao extends DatabaseAccessor<AppDatabase> with _$TasksDaoMixin {
  TasksDao(super.db);

  /// Получить все активные задачи (не done, не cancelled).
  ///
  /// Шаблоны повторяющихся задач по умолчанию скрыты — вместо них в списке
  /// фигурируют материализованные экземпляры. Передайте
  /// [includeTemplates] = true, чтобы увидеть сам шаблон серии
  /// (например для редактирования частоты повторения).
  Future<List<Task>> getActive({bool includeTemplates = false}) async {
    return await (select(tasks)
          ..where((t) => _activeStatuses(t) &
              _templateFilters(t, includeTemplates)))
        .get();
  }

  /// Получить просроченные задачи
  Future<List<Task>> getOverdue() async {
    final now = DateTime.now();
    return await (select(tasks)
          ..where((t) =>
              t.deadline.isSmallerThanValue(now) &
              _activeStatuses(t) &
              _templateFilters(t, false)))
        .get();
  }

  /// Получить задачи запланированные на конкретную дату.
  /// Шаблоны серий исключаются (их место занимают экземпляры).
  Future<List<Task>> getScheduledForDate(DateTime date) async {
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(const Duration(days: 1));
    return await (select(tasks)
          ..where((t) =>
              t.scheduledDate.isBiggerOrEqualValue(start) &
              t.scheduledDate.isSmallerThanValue(end) &
              _templateFilters(t, false)))
        .get();
  }

  /// Получить задачи по квадранту матрицы Эйзенхауэра
  Future<List<Task>> getEisenhowerQuadrant(String quadrant) async {
    Expression<bool> Function(
        Expression<int> importance, Expression<int> urgency) predicate;

    switch (quadrant) {
      case 'urgent_important':
        predicate =
            (i, u) => i.isBiggerOrEqualValue(3) & u.isBiggerOrEqualValue(3);
        break;
      case 'important_not_urgent':
        predicate =
            (i, u) => i.isBiggerOrEqualValue(3) & u.isSmallerThanValue(3);
        break;
      case 'urgent_not_important':
        predicate =
            (i, u) => i.isSmallerThanValue(3) & u.isBiggerOrEqualValue(3);
        break;
      case 'not_urgent_not_important':
        predicate = (i, u) => i.isSmallerThanValue(3) & u.isSmallerThanValue(3);
        break;
      default:
        throw ArgumentError('Unknown quadrant: $quadrant');
    }

    return await (select(tasks)
          ..where((t) => predicate(t.importance, t.urgency)))
        .get();
  }

  /// Получить задачу по ID
  Future<Task?> getById(int id) async {
    return await (select(tasks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Все активные «шаблоны» повторяющихся задач (recurrence != none).
  /// Готовые/отменённые шаблоны не возвращаются — серия считается завершённой,
  /// материализатор перестаёт создавать новые экземпляры.
  Future<List<Task>> getRecurringTemplates() async {
    return await (select(tasks)
          ..where((t) =>
              (t.status.equals(TaskStatus.backlog.name) |
                  t.status.equals(TaskStatus.todo.name) |
                  t.status.equals(TaskStatus.inProgress.name) |
                  t.status.equals(TaskStatus.waiting.name)) &
              t.recurrence.isNotValue(TaskRecurrence.none.name)))
        .get();
  }

  /// Экземпляры заданного шаблона серии (parentId == templateId).
  Future<List<Task>> getChildrenOf(int templateId) async {
    return await (select(tasks)..where((t) => t.parentId.equals(templateId)))
        .get();
  }

  /// Создать новую задачу
  Future<int> create({
    required String title,
    String? description,
    int? projectId,
    TaskStatus status = TaskStatus.backlog,
    int importance = 2,
    int urgency = 2,
    DateTime? deadline,
    DateTime? scheduledDate,
    int? estimatedMinutes,
    TaskRecurrence recurrence = TaskRecurrence.none,
    int repeatInterval = 1,
    DateTime? repeatEndDate,
    int? parentId,
  }) async {
    return await into(tasks).insert(
      TasksCompanion.insert(
        title: title,
        description: Value(description),
        projectId: Value(projectId),
        status: Value(status),
        importance: Value(importance),
        urgency: Value(urgency),
        deadline: Value(deadline),
        scheduledDate: Value(scheduledDate),
        estimatedMinutes: Value(estimatedMinutes),
        recurrence: Value(recurrence),
        repeatInterval: Value(repeatInterval),
        repeatEndDate: Value(repeatEndDate),
        parentId: Value(parentId),
      ),
    );
  }

  /// Обновить задачу по ID
  Future<int> updateTask(
    int id, {
    String? title,
    String? description,
    int? projectId,
    TaskStatus? status,
    int? importance,
    int? urgency,
    DateTime? deadline,
    DateTime? scheduledDate,
    int? estimatedMinutes,
    int? actualMinutes,
    TaskRecurrence? recurrence,
    int? repeatInterval,
    DateTime? repeatEndDate,
    int? parentId,
  }) async {
    return await (update(tasks)..where((t) => t.id.equals(id))).write(
      TasksCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        description:
            description != null ? Value(description) : const Value.absent(),
        projectId: projectId != null ? Value(projectId) : const Value.absent(),
        status: status != null ? Value(status) : const Value.absent(),
        importance:
            importance != null ? Value(importance) : const Value.absent(),
        urgency: urgency != null ? Value(urgency) : const Value.absent(),
        deadline: deadline != null ? Value(deadline) : const Value.absent(),
        scheduledDate:
            scheduledDate != null ? Value(scheduledDate) : const Value.absent(),
        estimatedMinutes: estimatedMinutes != null
            ? Value(estimatedMinutes)
            : const Value.absent(),
        actualMinutes:
            actualMinutes != null ? Value(actualMinutes) : const Value.absent(),
        recurrence:
            recurrence != null ? Value(recurrence) : const Value.absent(),
        repeatInterval: repeatInterval != null
            ? Value(repeatInterval)
            : const Value.absent(),
        repeatEndDate:
            repeatEndDate != null ? Value(repeatEndDate) : const Value.absent(),
        parentId: parentId != null ? Value(parentId) : const Value.absent(),
      ),
    );
  }

  /// Завершить задачу
  Future<int> complete(int id) async {
    return await (update(tasks)..where((t) => t.id.equals(id))).write(
      TasksCompanion(
        status: const Value(TaskStatus.done),
        completedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Изменить статус задачи
  Future<int> changeStatus(int id, TaskStatus newStatus) async {
    final companion = newStatus == TaskStatus.done
        ? TasksCompanion(
            status: Value(newStatus),
            completedAt: Value(DateTime.now()),
          )
        : TasksCompanion(status: Value(newStatus));
    return await (update(tasks)..where((t) => t.id.equals(id)))
        .write(companion);
  }

  /// Перенести задачу на другую дату
  Future<int> reschedule(int id, DateTime newDate) async {
    return await (update(tasks)..where((t) => t.id.equals(id))).write(
      TasksCompanion(scheduledDate: Value(newDate)),
    );
  }

  /// Удалить задачу по ID
  Future<int> deleteById(int id) async {
    return await (delete(tasks)..where((t) => t.id.equals(id))).go();
  }

  /// Reactive stream активных задач
  Stream<List<Task>> watchActive() {
    return (select(tasks)
          ..where((t) =>
              _activeStatuses(t) & _templateFilters(t, false)))
        .watch();
  }

  /// Reactive stream просроченных задач
  Stream<List<Task>> watchOverdue() {
    final now = DateTime.now();
    return (select(tasks)
          ..where((t) =>
              t.deadline.isSmallerThanValue(now) &
              _activeStatuses(t) &
              _templateFilters(t, false)))
        .watch();
  }

  /// Статусы, считающиеся «активными» (не done, не cancelled).
  Expression<bool> _activeStatuses($TasksTable t) {
    return t.status.equals(TaskStatus.backlog.name) |
        t.status.equals(TaskStatus.todo.name) |
        t.status.equals(TaskStatus.inProgress.name) |
        t.status.equals(TaskStatus.waiting.name);
  }

  /// Фильтр шаблонов серий: по умолчанию скрываем, при
  /// [includeTemplates] = true — показываем все recurrence.
  Expression<bool> _templateFilters($TasksTable t, bool includeTemplates) {
    return includeTemplates
        ? const Constant(true)
        : t.recurrence.equals(TaskRecurrence.none.name);
  }
}
