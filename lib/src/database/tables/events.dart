import 'package:drift/drift.dart';

/// Типы повторения событий.
/// Enum маппится в БД как строка через textEnum<Recurrence>().
enum Recurrence {
  none, // Без повторений
  daily, // Каждый день
  weekly, // Каждую неделю
  monthly, // Каждый месяц
  yearly, // Каждый год (для дней рождения)
}

/// Битовая маска дней недели — ограничивает, в какие дни повторяется событие.
///
/// Бит 0 — понедельник, бит 1 — вторник, … бит 6 — воскресенье.
/// Типичные сценарии:
///   - рабочий блок по будням: `recurrence = daily`, `byWeekdays = Weekdays.weekdays`
///   - планка по понедельникам и средам: `recurrence = weekly`,
///     `byWeekdays = Weekdays.monday | Weekdays.wednesday`
///
/// Маска `0` означает «любой день» и равносильна [Weekdays.all] (127),
/// поэтому хранить все дни явно не требуется.
class Weekdays {
  const Weekdays._();

  static const int monday = 1 << 0; // 1
  static const int tuesday = 1 << 1; // 2
  static const int wednesday = 1 << 2; // 4
  static const int thursday = 1 << 3; // 8
  static const int friday = 1 << 4; // 16
  static const int saturday = 1 << 5; // 32
  static const int sunday = 1 << 6; // 64

  /// Понедельник — пятница.
  static const int weekdays =
      monday | tuesday | wednesday | thursday | friday; // 31

  /// Суббота и воскресенье.
  static const int weekend = saturday | sunday; // 96

  /// Все дни недели.
  static const int all = weekdays | weekend; // 127

  /// Маска корректна, если это 0 или подмножество [all].
  static bool isValid(int mask) => mask >= 0 && mask <= all;

  /// Разворачивает маску в список коротких названий дней (`['mon', 'wed']`).
  /// Нужен для JSON-ответов, чтобы клиенту не приходилось знать биты.
  static List<String> expand(int mask) {
    const names = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    return [
      for (var i = 0; i < names.length; i++)
        if (mask & (1 << i) != 0) names[i],
    ];
  }

  /// Собирает маску из названий дней: `['mon', 'wed']` → 5.
  /// Возвращает `null`, если встретилось нераспознанное имя.
  static int? fromNames(Iterable<String> names) {
    const lookup = {
      'mon': monday,
      'monday': monday,
      'tue': tuesday,
      'tues': tuesday,
      'tuesday': tuesday,
      'wed': wednesday,
      'weds': wednesday,
      'wednesday': wednesday,
      'thu': thursday,
      'thur': thursday,
      'thurs': thursday,
      'thursday': thursday,
      'fri': friday,
      'friday': friday,
      'sat': saturday,
      'saturday': saturday,
      'sun': sunday,
      'sunday': sunday,
    };

    var mask = 0;
    for (final raw in names) {
      final bit = lookup[raw.trim().toLowerCase()];
      if (bit == null) return null;
      mask |= bit;
    }
    return mask;
  }
}

/// Бит дня недели для [DateTime] (0 = понедельник … 6 = воскресенье).
/// Год и месяц не важны — нужен только фактический день недели.
int weekdayBitOf(DateTime date) {
  // DateTime.monday == 1 … DateTime.sunday == 7
  return 1 << (date.weekday - 1);
}

/// События и важные даты.
/// В отличие от задач, событие — это что-то, что происходит во времени
/// (встреча, созвон, день рождения). Его нельзя «выполнить», можно только пропустить.

@DataClassName('Event')
class Events extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Название события (до 200 символов).
  TextColumn get title => text().withLength(min: 1, max: 200)();

  /// Дата+время начала события.
  DateTimeColumn get startsAt => dateTime()();

  /// Дата+время окончания события (UTC).
  ///
  /// `null` — окончание не выражено: событие «на весь день» либо длительность
  /// не задана. Для событий с временем поле обязательно заполнять: без него
  /// блок вида «рабочий блок 10:00–12:00» не выразить, и план дня вынужден
  /// был бы угадывать длительность.
  DateTimeColumn get endsAt => dateTime().nullable()();

  /// Флаг «на весь день». Используется для дат типа дня рождения,
  /// когда конкретное время не имеет значения.
  BoolColumn get isAllDay => boolean().withDefault(const Constant(false))();

  /// Тип повторения (см. Recurrence).
  // Constant принимает SQL-значение (строку), а не Dart-enum.
  TextColumn get recurrence =>
      textEnum<Recurrence>().withDefault(const Constant('none'))();

  /// Битовая маска дней недели для повторений (см. [Weekdays]).
  ///
  /// `0` — любой день, равносильно [Weekdays.all]. Игнорируется при
  /// `recurrence = Recurrence.none`. Работает в паре с [recurrence]:
  /// `daily` + маска будней = «каждый будний день».
  IntColumn get byWeekdays => integer().withDefault(const Constant(0))();

  /// Событие «мягкое»: может пересекаться с другими событиями и само по себе
  /// не считается конфликтом при планировании.
  ///
  /// Правило: два события конфликтуют, если их интервалы пересекаются
  /// и оба жёсткие (`canOverlap = false`).
  ///
  /// Пример: рабочий блок 10:00–12:00 — жёсткий блок (`canOverlap = false`),
  /// а звонок «записаться на приём к врачу» на 5 минут внутри него — мягкий
  /// (`canOverlap = true`): время занято блоком, но сам звонок блок не ломает.
  BoolColumn get canOverlap => boolean().withDefault(const Constant(false))();

  /// За сколько минут до события прислать напоминание.
  IntColumn get remindMinutesBefore =>
      integer().withDefault(const Constant(30))();

  /// Место проведения (опционально).
  TextColumn get location => text().nullable()();

  /// Дата и время создания.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
