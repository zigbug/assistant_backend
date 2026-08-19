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
    bool isAllDay = false,
    Recurrence recurrence = Recurrence.none,
    int remindMinutesBefore = 30,
    String? location,
  }) async {
    return await into(events).insert(
      EventsCompanion.insert(
        title: title,
        startsAt: startsAt,
        isAllDay: Value(isAllDay),
        recurrence: Value(recurrence),
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
    bool? isAllDay,
    Recurrence? recurrence,
    int? remindMinutesBefore,
    String? location,
  }) async {
    return await (update(events)..where((e) => e.id.equals(id))).write(
      EventsCompanion(
        title: title != null ? Value(title) : const Value.absent(),
        startsAt: startsAt != null ? Value(startsAt) : const Value.absent(),
        isAllDay: isAllDay != null ? Value(isAllDay) : const Value.absent(),
        recurrence:
            recurrence != null ? Value(recurrence) : const Value.absent(),
        remindMinutesBefore: remindMinutesBefore != null
            ? Value(remindMinutesBefore)
            : const Value.absent(),
        location:
            location != null ? Value(location) : const Value.absent(),
      ),
    );
  }

  /// Удалить событие по ID
  Future<int> deleteById(int id) async {
    return await (delete(events)..where((e) => e.id.equals(id))).go();
  }

  /// Получить все события (для синхронизации)
  Future<List<Event>> getAll() async {
    return await select(events).get();
  }
}