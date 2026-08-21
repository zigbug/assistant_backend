import 'package:drift/drift.dart';

/// Типы повторения событий.
/// Enum маппится в БД как строка через textEnum<Recurrence>().
enum Recurrence {
  none,      // Без повторений
  daily,     // Каждый день
  weekly,    // Каждую неделю
  monthly,   // Каждый месяц
  yearly,    // Каждый год (для дней рождения)
}

/// События и важные даты.
/// В отличие от задач, событие — это что-то, что происходит во времени
/// (встреча, созвон, день рождения). Его нельзя «выполнить», можно только пропустить.
///
/// Аннотация DataClassName генерирует модель Event с методом toJson(),
/// который используется в HTTP API для сериализации в JSON.
@DataClassName('Event', useJson: true)
class Events extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Название события (до 200 символов).
  TextColumn get title => text().withLength(min: 1, max: 200)();

  /// Дата+время начала события.
  DateTimeColumn get startsAt => dateTime()();

  /// Флаг «на весь день». Используется для дат типа дня рождения,
  /// когда конкретное время не имеет значения.
  BoolColumn get isAllDay =>
      boolean().withDefault(const Constant(false))();

  /// Тип повторения (см. Recurrence).
  // Constant принимает SQL-значение (строку), а не Dart-enum.
  TextColumn get recurrence => textEnum<Recurrence>()
      .withDefault(const Constant('none'))();

  /// За сколько минут до события прислать напоминание.
  IntColumn get remindMinutesBefore =>
      integer().withDefault(const Constant(30))();

  /// Место проведения (опционально).
  TextColumn get location => text().nullable()();

  /// Дата и время создания.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
}
