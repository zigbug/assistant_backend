import 'package:drift/drift.dart';
import 'daily_plans.dart';

/// Типы элементов плана дня.
enum PlanItemType {
  task, // Ссылка на задачу (ref_id → tasks.id)
  event, // Ссылка на событие (ref_id → events.id)
  habit, // Привычка (в v2 — отдельная таблица)
  breakSlot, // Перерыв/обед (без ссылки)
}

/// Статусы элемента плана.
enum PlanItemStatus {
  planned, // 📋 В плане, время ещё не пришло
  inProgress, // ▶️ Выполняется прямо сейчас (пользователь нажал "начать")
  done, // ✅ Сделано в отведённое время
  skipped, // ⏭️ Пропущено
  moved, // 📅 Перенесено на другой день/слот
  cancelled, // ❌ Отменено (не путать со skipped — отменено до начала)
}

/// Отдельный слот плана дня (time blocking).
/// Каждый элемент — это отрезок времени с привязкой к задаче/событию/привычке.
///
@DataClassName('DailyPlanItem')
class DailyPlanItems extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Ссылка на родительский план дня.
  IntColumn get planId => integer().references(DailyPlans, #id)();

  /// Тип элемента (task/event/habit/break).
  TextColumn get itemType => textEnum<PlanItemType>()();

  /// Ссылка на конкретную задачу/событие (nullable для перерывов).
  /// Не используем FK напрямую, т.к. ссылается на разные таблицы —
  /// целостность проверяется на уровне бизнес-логики.
  IntColumn get refId => integer().nullable()();

  /// Время начала слота.
  DateTimeColumn get startTime => dateTime()();

  /// Время окончания слота (nullable для задач без оценки).
  DateTimeColumn get endTime => dateTime().nullable()();

  /// Статус элемента плана (см. PlanItemStatus).
  // Constant принимает SQL-значение (строку), а не Dart-enum.
  TextColumn get status =>
      textEnum<PlanItemStatus>().withDefault(const Constant('planned'))();

  /// Заметка/комментарий к слоту (например «отложили, потому что пришёл клиент»).
  TextColumn get note => text().nullable()();
}
