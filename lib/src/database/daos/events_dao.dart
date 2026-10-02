import 'package:drift/drift.dart';

import '../database.dart';

part 'events_dao.g.dart';

/// DAO для работы с событиями
@DriftAccessor(tables: [Events])
class EventsDao extends DatabaseAccessor<AppDatabase> with _$EventsDaoMixin {
  EventsDao(super.db);

  /// Получить все события на сегодня
  Future<List<Event>> getToday() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));
    return await (select(events)
          ..where((e) =>
              e.startsAt.isBiggerOrEqualValue(start) &
              e.startsAt.isSmallerThanValue(end)))
        .get();
  }

  /// Получить все будущие события
  Future<List<Event>> getUpcoming({int days = 7}) async {
    final now = DateTime.now();
    final end = now.add(Duration(days: days));
    return await (select(events)
          ..where((e) =>
              e.startsAt.isBiggerOrEqualValue(now) &
              e.startsAt.isSmallerThanValue(end)))
        .get();
  }

  /// Получить событие по ID
  Future<Event?> getById(int id) async {
    return await (select(events)..where((e) => e.id.equals(id)))
        .getSingleOrNull();
  }

  /// Создать новое событие
  Future<int> create({
    required String title,
    required DateTime startsAt,
    DateTime? endsAt,
    bool isAllDay = false,
    Recurrence recurrence = Recurrence.none,
    int byWeekdays = 0,
    bool canOverlap = false,
    int remindMinutesBefore = 30,
    String? location,
  }) async {
    return await into(events).insert(
      EventsCompanion.insert(
        title: title,
        startsAt: startsAt,
        endsAt: Value(endsAt),
        isAllDay: Value(isAllDay),
        recurrence: Value(recurrence),
        byWeekdays: Value(byWeekdays),
        canOverlap: Value(canOverlap),
        remindMinutesBefore: Value(remindMinutesBefore),
        location: Value(location),
      ),
    );
  }

  /// Обновить событие по ID
  Future<int> updateEvent(
    int id, {
    String? title,
    DateTime? startsAt,
    DateTime? endsAt,
    bool clearEndsAt = false,
    bool? isAllDay,
    Recurrence? recurrence,
    int? byWeekdays,
    bool? canOverlap,
    int? remindMinutesBefore,
    String? location,
  }) async {
    return await (update(events)..where((e) => e.id.equals(id))).write(
      EventsCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        startsAt: startsAt != null ? Value(startsAt) : const Value.absent(),
        endsAt: clearEndsAt
            ? const Value(null)
            : endsAt != null
                ? Value(endsAt)
                : const Value.absent(),
        isAllDay: isAllDay != null ? Value(isAllDay) : const Value.absent(),
        recurrence:
            recurrence != null ? Value(recurrence) : const Value.absent(),
        byWeekdays:
            byWeekdays != null ? Value(byWeekdays) : const Value.absent(),
        canOverlap:
            canOverlap != null ? Value(canOverlap) : const Value.absent(),
        remindMinutesBefore: remindMinutesBefore != null
            ? Value(remindMinutesBefore)
            : const Value.absent(),
        location: location != null ? Value(location) : const Value.absent(),
      ),
    );
  }

  /// Удалить событие по ID
  Future<int> deleteById(int id) async {
    return await (delete(events)..where((e) => e.id.equals(id))).go();
  }

  /// Найти жёсткие события, пересекающиеся с интервалом `[start, end)`.
  ///
  /// Мягкие события ([canOverlap] = true) конфликтами не считаются: по замыслу
  /// они умещаются внутрь блоков (звонок на 5 минут внутри рабочего блока)
  /// и не должны вытеснять из плана жёсткие блоки.
  ///
  /// События без [Event.endsAt] (окончание не выражено) считаются занятыми,
  /// если начались внутри интервала — их длительность неизвестна, поэтому
  /// трактуем их консервативно.
  Future<List<Event>> getConflicting(DateTime start, DateTime end) async {
    final startUtc = start.toUtc();
    final endUtc = end.toUtc();

    return await (select(events)
          ..where((e) =>
              e.canOverlap.equals(false) &
              e.startsAt.isSmallerThanValue(endUtc) &
              (e.endsAt.isBiggerThanValue(startUtc) |
                  (e.endsAt.isNull() &
                      e.startsAt.isBiggerOrEqualValue(startUtc)))))
        .get();
  }

  /// Все события (для синхронизации)
  Future<List<Event>> getAll() async {
    return await select(events).get();
  }
}
