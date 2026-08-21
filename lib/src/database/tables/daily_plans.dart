import 'package:drift/drift.dart';

/// Статус плана дня.
enum PlanStatus {
  draft, // Черновик (AI составил, ещё не подтверждён)
  confirmed, // Подтверждён пользователем
  done, // День прошёл, план можно анализировать
}

/// План дня — контейнер для списка задач/событий на конкретный день.
/// AI генерирует план через эндпоинт /api/v1/daily-plans/generate,
/// учитывая задачи с scheduledDate, события, привычки и preferences.

@DataClassName('DailyPlan')
class DailyPlans extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Дата дня (хранится как дата без времени — время у элементов плана).
  DateTimeColumn get date => dateTime()();

  /// Статус плана (см. PlanStatus).
  // Constant принимает SQL-значение (строку), а не Dart-enum.
  TextColumn get status =>
      textEnum<PlanStatus>().withDefault(const Constant('draft'))();

  /// Комментарий AI к плану: почему он расставил задачи именно так,
  /// какие риски видит, что советует пересмотреть.
  TextColumn get aiComment => text().nullable()();

  /// Уникальный ключ: на один день — один план.
  @override
  List<Set<Column>> get uniqueKeys => [
        {date}
      ];
}
