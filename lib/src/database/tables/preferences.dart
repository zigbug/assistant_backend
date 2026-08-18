import 'package:drift/drift.dart';

/// Настройки и предпочтения пользователя — ключ-value хранилище.
///
/// Примеры ключей:
///   - work_start        → "09:00"
///   - work_end          → "19:00"
///   - lunch_start       → "13:00"
///   - lunch_end         → "14:00"
///   - peak_hours        → "morning" | "afternoon" | "evening"
///   - no_schedule_after → "22:00"
///   - timezone          → "Europe/Moscow"
///   - notify_morning    → "true"
///   - notify_evening    → "true"
///
/// AI читает эту таблицу при составлении плана дня,
/// чтобы не ставить задачи на время обеда и не будить ночью.
class Preferences extends Table {
  /// Ключ настройки (уникальный).
  TextColumn get key => text().withLength(min: 1, max: 100)();

  /// Значение настройки (хранится как строка для простоты).
  /// Тип данных определяется по ключу на уровне бизнес-логики.
  TextColumn get value => text()();

  /// Дата и время последнего изменения.
  DateTimeColumn get updatedAt =>
      dateTime().withDefault(currentDateAndTime)();

  /// Первичный ключ — только key (строковое хранилище).
  @override
  Set<Column> get primaryKey => {key};
}
