import '../database/database.dart';
import '../database/daos/tasks_dao.dart';

/// Результат одного прохода материализации.
class MaterializerResult {
  const MaterializerResult({
    required this.created,
    required this.templatesProcessed,
    required this.nowUtc,
  });

  /// Сколько экземпляров создано за проход.
  final int created;

  /// Сколько шаблонов серий было обработано.
  final int templatesProcessed;

  /// Момент, относительно которого велась материализация (UTC).
  final DateTime nowUtc;

  Map<String, dynamic> toJson() => {
        'created': created,
        'templatesProcessed': templatesProcessed,
        'nowUtc': nowUtc.toIso8601String(),
      };
}

/// Материализатор повторяющихся задач.
///
/// Для каждого активного шаблона (`recurrence != none`) заранее создаёт
/// конкретные экземпляры-задачи (с `parentId` → шаблон) на N дней вперёд,
/// начиная с сегодняшнего дня. Операция идемпотентна: уже существующий
/// экземпляр на дату не дублируется.
///
/// Пример: шаблон «Разбирать почту» (daily, 09:00) → 30 задач-экземпляров,
/// по одной на каждый будущий день, со scheduledDate = 09:00.
class RecurringTaskMaterializer {
  RecurringTaskMaterializer(AppDatabase db) : _tasksDao = TasksDao(db);

  final TasksDao _tasksDao;

  /// Максимально допустимое число шагов на один шаблон (защита от беск. цикла).
  static const int _maxOccurrencesPerTemplate = 400;

  /// Выполнить материализацию. Идемпотентно — безопасно вызывать повторно.
  Future<MaterializerResult> materializeUpTo({
    required DateTime now,
    int horizonDays = 30,
  }) async {
    final nowUtc = now.toUtc();
    final templates = await _tasksDao.getRecurringTemplates();

    var createdTotal = 0;
    for (final template in templates) {
      createdTotal += await _materializeTemplate(template, nowUtc, horizonDays);
    }

    return MaterializerResult(
      created: createdTotal,
      templatesProcessed: templates.length,
      nowUtc: nowUtc,
    );
  }

  Future<int> _materializeTemplate(
    Task template,
    DateTime nowUtc,
    int horizonDays,
  ) async {
    final anchor = template.scheduledDate ?? template.createdAt;
    final interval = template.repeatInterval < 1 ? 1 : template.repeatInterval;

    // Границы серии: [anchor, effectiveEnd].
    final horizonEnd = nowUtc.add(Duration(days: horizonDays));
    final repeatEnd = template.repeatEndDate?.toUtc();
    final end = (repeatEnd != null && repeatEnd.isBefore(horizonEnd))
        ? repeatEnd
        : horizonEnd;

    // Уже материализованные даты (по дням, UTC), чтобы не дублировать.
    final existing = <DateTime>{};
    for (final child in await _tasksDao.getChildrenOf(template.id)) {
      if (child.scheduledDate != null) {
        existing.add(_day(child.scheduledDate!));
      }
    }

    // Прошлые даты не создаём: серия «наверстывается» только со сегодня.
    final today = _day(nowUtc);
    final anchorDay = _day(anchor);
    final startDay = anchorDay.isAfter(today) ? anchorDay : today;

    // Разворачиваем правило серии в конкретные даты.
    var current = anchor;
    var created = 0;
    var guard = 0;
    while (guard < _maxOccurrencesPerTemplate) {
      guard++;
      if (current.isAfter(end)) break;

      final day = _day(current);
      if (!day.isBefore(startDay) && !existing.contains(day)) {
        await _createOccurrence(template, current, day);
        created++;
        existing.add(day);
      }
      current = _step(current, template.recurrence, interval);
    }

    return created;
  }

  Future<void> _createOccurrence(Task template, DateTime occurrence, DateTime day) async {
    final title =
        '${template.title} (${_shortDate(day)})';
    await _tasksDao.create(
      title: title,
      description: template.description,
      projectId: template.projectId,
      status: TaskStatus.todo,
      importance: template.importance,
      urgency: template.urgency,
      scheduledDate: occurrence,
      estimatedMinutes: template.estimatedMinutes,
      recurrence: TaskRecurrence.none,
      repeatInterval: 1,
      parentId: template.id,
    );
  }

  /// Следующее значение даты по правилу повторения.
  DateTime _step(DateTime value, TaskRecurrence recurrence, int interval) {
    switch (recurrence) {
      case TaskRecurrence.daily:
        return value.add(Duration(days: interval));
      case TaskRecurrence.weekly:
        return value.add(Duration(days: 7 * interval));
      case TaskRecurrence.monthly:
        return _addMonths(value, interval);
      case TaskRecurrence.yearly:
        return _addMonths(value, interval * 12);
      case TaskRecurrence.none:
        return value;
    }
  }

  /// Прибавление месяцев с защитой от переполнения дня месяца:
  /// 31 января + 1 месяц → 28 февраля (не 3 марта).
  DateTime _addMonths(DateTime dt, int months) {
    final total = dt.month - 1 + months;
    var year = dt.year + (total ~/ 12);
    var month = (total % 12) + 1;
    if (month <= 0) {
      month += 12;
      year -= 1;
    }
    final lastDay = DateTime.utc(year, month + 1, 0).day;
    final day = dt.day > lastDay ? lastDay : dt.day;
    return DateTime.utc(
      year,
      month,
      day,
      dt.hour,
      dt.minute,
      dt.second,
      dt.millisecond,
      dt.microsecond,
    );
  }

  DateTime _day(DateTime dt) {
    final u = dt.toUtc();
    return DateTime.utc(u.year, u.month, u.day);
  }

  String _shortDate(DateTime day) {
    final d = day.toIso8601String().substring(0, 10); // YYYY-MM-DD
    return d;
  }
}