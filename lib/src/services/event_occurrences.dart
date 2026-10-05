import '../database/tables/events.dart';

/// Одно появление повторяющегося события в конкретный день.
///
/// Событие в базе хранится один раз, а в плане дня должно появиться в каждом
/// дне, который попадает под `recurrence` + `byWeekdays`. [EventOccurrence] —
/// это «материализованное» появление: собственные `start`/`end` в UTC.
class EventOccurrence {
  const EventOccurrence({
    required this.eventId,
    required this.start,
    required this.end,
  });

  /// ID события-шаблона (тот же, что у исходной строки `events`).
  final int eventId;

  /// Начало появления (UTC).
  final DateTime start;

  /// Окончание появления (UTC) либо `null`, если у события не задано `endsAt`.
  final DateTime? end;
}

/// Полночь UTC указанного дня — граница, по которой план делит сутки.
DateTime midnightUtc(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

/// Разворачивает повторяющееся событие на конкретный UTC-день.
///
/// Возвращает `null`, если в этот день событие не происходит. День базового
/// события (`startsAt`) тоже возвращает `null`: его и так подхватит прямой
/// выбор по `startsAt`, иначе база попадёт в план дважды.
///
/// Длительность сохраняется: `end = start + (endsAt - startsAt)`, поэтому
/// блок «09:00–14:00» остаётся пятичасовым в каждом дне.
///
/// [byWeekdays] — битовая маска [Weekdays]; `0` означает «любой день».
/// Если маска задана, она важнее интервала повтора: `weekly` + маска будней
/// даёт «каждый будний день», а не «раз в неделю».
EventOccurrence? occurrenceOn({
  required int eventId,
  required DateTime startsAt,
  required DateTime? endsAt,
  required Recurrence recurrence,
  required int byWeekdays,
  required DateTime dayUtc,
}) {
  if (recurrence == Recurrence.none) return null;

  final baseDay = midnightUtc(startsAt);
  final targetDay = midnightUtc(dayUtc);

  // База и всё, что до неё, — не наш день (база приходит прямым выбором).
  if (!targetDay.isAfter(baseDay)) return null;

  final mask = byWeekdays == 0 ? Weekdays.all : byWeekdays;
  final hasMask = byWeekdays != 0;
  final dayDiff = targetDay.difference(baseDay).inDays;

  final bool occurs;
  switch (recurrence) {
    case Recurrence.daily:
      occurs = weekdayBitOf(targetDay) & mask != 0;
    case Recurrence.weekly:
      occurs = hasMask
          ? weekdayBitOf(targetDay) & mask != 0
          : dayDiff % 7 == 0;
    case Recurrence.monthly:
      occurs = hasMask
          ? weekdayBitOf(targetDay) & mask != 0
          : targetDay.day == _clampedDayOfMonth(baseDay, targetDay);
    case Recurrence.yearly:
      occurs = hasMask
          ? weekdayBitOf(targetDay) & mask != 0
          : targetDay.month == baseDay.month &&
              targetDay.day == _clampedDayOfMonth(baseDay, targetDay);
    case Recurrence.none:
      occurs = false;
  }

  if (!occurs) return null;

  final start = DateTime.utc(
    targetDay.year,
    targetDay.month,
    targetDay.day,
    startsAt.hour,
    startsAt.minute,
    startsAt.second,
    startsAt.millisecond,
    startsAt.microsecond,
  );

  final duration = endsAt?.difference(startsAt);
  DateTime? end;
  if (duration != null) end = start.add(duration);

  return EventOccurrence(eventId: eventId, start: start, end: end);
}

/// День месяца базового события, обрезанный по длине целевого месяца.
///
/// Нужно для «31-го числа»: в феврале такого дня нет, и повтор должен
/// приходиться на 28-е (или 29-е в високосный год), а не исчезать совсем.
int _clampedDayOfMonth(DateTime baseDay, DateTime targetDay) {
  final lastDay = DateTime.utc(targetDay.year, targetDay.month + 1, 0).day;
  return baseDay.day > lastDay ? lastDay : baseDay.day;
}
