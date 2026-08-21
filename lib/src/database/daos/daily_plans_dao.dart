import 'package:drift/drift.dart';

import '../database.dart';

part 'daily_plans_dao.g.dart';

/// DAO для работы с планами дня и их элементами
@DriftAccessor(tables: [DailyPlans, DailyPlanItems])
class DailyPlansDao extends DatabaseAccessor<AppDatabase>
    with _$DailyPlansDaoMixin {
  DailyPlansDao(super.db);

  /// Получить или создать план на конкретную дату
  Future<DailyPlan> getOrCreateForDate(DateTime date) async {
    final normalized = DateTime(date.year, date.month, date.day);
    final existing = await (select(dailyPlans)
          ..where((p) => p.date.equals(normalized)))
        .getSingleOrNull();
    if (existing != null) return existing;

    final id = await into(dailyPlans).insert(
      DailyPlansCompanion.insert(
        date: normalized,
        status: const Value(PlanStatus.draft),
      ),
    );
    return await (select(dailyPlans)..where((p) => p.id.equals(id)))
        .getSingle();
  }

  /// Получить план на сегодня
  Future<DailyPlan?> getToday() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return await (select(dailyPlans)..where((p) => p.date.equals(today)))
        .getSingleOrNull();
  }

  /// Получить план по ID
  Future<DailyPlan?> getById(int id) async {
    return await (select(dailyPlans)..where((p) => p.id.equals(id)))
        .getSingleOrNull();
  }

  /// Добавить элемент в план (задачу, событие, перерыв).
  ///
  /// [startTime] — время начала (обязательно).
  /// [endTime] — время окончания (опционально). Для событий на весь день
  /// или задач без оценки времени можно передавать null.
  ///
  /// [status] по умолчанию — `planned`, т.к. только что добавленный элемент
  /// ещё не начал выполняться. В `inProgress` его переведёт пользователь
  /// через Flutter-приложение, когда нажмёт "Начать".
  Future<int> addItem({
    required int planId,
    required PlanItemType itemType,
    int? refId,
    required DateTime startTime,
    DateTime? endTime,
    String? note,
    PlanItemStatus status = PlanItemStatus.planned, // ← planned вместо pending
  }) async {
    return await into(dailyPlanItems).insert(
      DailyPlanItemsCompanion.insert(
        planId: planId,
        itemType: itemType,
        refId: Value(refId),
        startTime: startTime,
        endTime: Value(endTime),
        note: Value(note),
        status: Value(status),
      ),
    );
  }

  /// Получить все элементы плана
  Future<List<DailyPlanItem>> getItems(int planId) async {
    return await (select(dailyPlanItems)
          ..where((i) => i.planId.equals(planId))
          ..orderBy([(i) => OrderingTerm.asc(i.startTime)]))
        .get();
  }

  /// Получить план со всеми элементами
  Future<({DailyPlan plan, List<DailyPlanItem> items})> getPlanWithItems(
      int planId) async {
    final plan = await (select(dailyPlans)..where((p) => p.id.equals(planId)))
        .getSingle();
    final items = await getItems(planId);
    return (plan: plan, items: items);
  }

  /// Обновить статус элемента
  Future<int> updateItemStatus(int itemId, PlanItemStatus newStatus,
      {String? note}) async {
    return await (update(dailyPlanItems)..where((i) => i.id.equals(itemId)))
        .write(
      DailyPlanItemsCompanion(
        status: Value(newStatus),
        note: note != null ? Value(note) : const Value.absent(),
      ),
    );
  }

  /// Перенести элемент на другое время
  Future<int> rescheduleItem(
      int itemId, DateTime newStart, DateTime newEnd) async {
    return await (update(dailyPlanItems)..where((i) => i.id.equals(itemId)))
        .write(
      DailyPlanItemsCompanion(
        startTime: Value(newStart),
        endTime: Value(newEnd),
      ),
    );
  }

  /// Обновить статус плана
  Future<int> updatePlanStatus(int planId, PlanStatus newStatus) async {
    return await (update(dailyPlans)..where((p) => p.id.equals(planId))).write(
      DailyPlansCompanion(status: Value(newStatus)),
    );
  }

  /// Обновить AI-комментарий к плану
  Future<int> updateAiComment(int planId, String comment) async {
    return await (update(dailyPlans)..where((p) => p.id.equals(planId))).write(
      DailyPlansCompanion(aiComment: Value(comment)),
    );
  }

  /// Удалить элемент плана по ID
  Future<int> deleteItemById(int itemId) async {
    return await (delete(dailyPlanItems)..where((i) => i.id.equals(itemId)))
        .go();
  }

  /// Удалить план по ID (и все его элементы)
  Future<int> deletePlanById(int planId) async {
    // Сначала удаляем элементы
    await (delete(dailyPlanItems)..where((i) => i.planId.equals(planId))).go();
    // Затем удаляем сам план
    return await (delete(dailyPlans)..where((p) => p.id.equals(planId))).go();
  }
}
