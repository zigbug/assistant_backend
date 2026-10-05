import 'package:assistant_backend/src/database/tables/events.dart';
import 'package:assistant_backend/src/services/event_occurrences.dart';
import 'package:test/test.dart';

/// База: понедельник 05.10.2026, 09:00–14:00 UTC.
final base = DateTime.utc(2026, 10, 5, 9);

EventOccurrence? on(
  DateTime day, {
  Recurrence recurrence = Recurrence.daily,
  int byWeekdays = 0,
  int hours = 9,
  Duration? length = const Duration(hours: 5),
  DateTime? startsAt,
}) {
  final start = startsAt ?? DateTime.utc(2026, 10, 5, hours);
  return occurrenceOn(
    eventId: 1,
    startsAt: start,
    endsAt: length == null ? null : start.add(length),
    recurrence: recurrence,
    byWeekdays: byWeekdays,
    dayUtc: day,
  );
}

DateTime day(int d) => DateTime.utc(2026, 10, d);

void main() {
  group('Разворот повторяющихся событий', () {
    test('recurrence none не даёт появлений', () {
      expect(on(day(6), recurrence: Recurrence.none), isNull);
    });

    test('базовый день не дублируется', () {
      // Базовый день ловит прямой выбор по startsAt — разворот его не трогает.
      expect(on(day(5)), isNull);
    });

    test('день до базы не даёт появлений', () {
      expect(on(day(4)), isNull);
    });

    test('daily без маски — каждый день', () {
      expect(on(day(6)), isNotNull);
      expect(on(day(7)), isNotNull);
      expect(on(day(11)), isNotNull);
    });

    test('daily с маской будней — выходные пропущены', () {
      expect(on(day(6), byWeekdays: Weekdays.weekdays), isNotNull); // вт
      expect(on(day(9), byWeekdays: Weekdays.weekdays), isNotNull); // пт
      expect(on(day(10), byWeekdays: Weekdays.weekdays), isNull); // сб
      expect(on(day(11), byWeekdays: Weekdays.weekdays), isNull); // вс
    });

    test('weekly без маски — раз в неделю от базы', () {
      expect(on(day(12), recurrence: Recurrence.weekly), isNotNull);
      expect(on(day(19), recurrence: Recurrence.weekly), isNotNull);
      expect(on(day(13), recurrence: Recurrence.weekly), isNull);
    });

    test('weekly с маской — по маске, а не раз в неделю', () {
      // Пн и Ср: база — понедельник, 07.10 — среда той же недели.
      expect(on(day(7), recurrence: Recurrence.weekly, byWeekdays: Weekdays.monday | Weekdays.wednesday), isNotNull);
      expect(on(day(6), recurrence: Recurrence.weekly, byWeekdays: Weekdays.monday | Weekdays.wednesday), isNull);
      // Вторая неделя — те же дни.
      expect(on(day(14), recurrence: Recurrence.weekly, byWeekdays: Weekdays.monday | Weekdays.wednesday), isNotNull);
    });

    test('monthly по тому же числу', () {
      final start = DateTime.utc(2026, 10, 15, 9);
      expect(on(day(15), recurrence: Recurrence.monthly, startsAt: DateTime.utc(2026, 9, 15, 9)), isNotNull);
      expect(on(day(16), recurrence: Recurrence.monthly, startsAt: start), isNull);
      // 15.11 и 15.12 — тот же день месяца.
      expect(on(DateTime.utc(2026, 11, 15), recurrence: Recurrence.monthly, startsAt: start), isNotNull);
      expect(on(DateTime.utc(2026, 12, 15), recurrence: Recurrence.monthly, startsAt: start), isNotNull);
    });

    test('monthly 31-го обрезается по длине месяца', () {
      // База — 31.10, в ноябре такого дня нет: должно приходиться на 30.11.
      final start = DateTime.utc(2026, 10, 31, 9);
      expect(on(DateTime.utc(2026, 11, 30), recurrence: Recurrence.monthly, startsAt: start), isNotNull);
      expect(on(DateTime.utc(2026, 11, 29), recurrence: Recurrence.monthly, startsAt: start), isNull);
    });

    test('yearly по тому же месяцу и дню', () {
      final start = DateTime.utc(2026, 10, 5, 9);
      expect(on(DateTime.utc(2027, 10, 5), recurrence: Recurrence.yearly, startsAt: start), isNotNull);
      expect(on(DateTime.utc(2027, 10, 6), recurrence: Recurrence.yearly, startsAt: start), isNull);
      expect(on(DateTime.utc(2027, 11, 5), recurrence: Recurrence.yearly, startsAt: start), isNull);
    });

    test('длительность сохраняется в каждом появлении', () {
      final o = on(day(6));
      expect(o, isNotNull);
      expect(o!.start, DateTime.utc(2026, 10, 6, 9));
      expect(o.end, DateTime.utc(2026, 10, 6, 14));
      expect(o.end!.difference(o.start), const Duration(hours: 5));
    });

    test('время суток сохраняется, минуты не теряются', () {
      final o = on(day(6), hours: 15, length: const Duration(hours: 3));
      expect(o!.start, DateTime.utc(2026, 10, 6, 15));
      expect(o.end, DateTime.utc(2026, 10, 6, 18));
    });

    test('событие без endsAt даёт появление без конца', () {
      final o = on(day(6), length: null);
      expect(o, isNotNull);
      expect(o!.start, DateTime.utc(2026, 10, 6, 9));
      expect(o.end, isNull);
    });

    test('локальный DateTime из базы не сдвигает блок на offset', () {
      // Drift отдаёт колонку DateTime в локальной зоне процесса. Если брать
      // компоненты .hour и подставлять их в DateTime.utc, блок уедет на
      // offset: база 06:00Z превратилась бы в 09:00Z. Считаем время суток
      // как расстояние от полуночи UTC — тогда флаг isUtc не важен.
      final local = DateTime(2026, 10, 5, 9);
      final baseUtc = local.toUtc();
      final expected = DateTime.utc(2026, 10, 6)
          .add(baseUtc.difference(DateTime.utc(2026, 10, 5)));

      final o = occurrenceOn(
        eventId: 1,
        startsAt: local,
        endsAt: local.add(const Duration(hours: 5)),
        recurrence: Recurrence.daily,
        byWeekdays: 0,
        dayUtc: day(6),
      );

      expect(o!.start, expected);
      expect(o.start.isUtc, isTrue);
      expect(o.end!.difference(o.start), const Duration(hours: 5));
    });

    test('ночное событие не уезжает на соседний день', () {
      // 23:30–00:30: начало в нужном дне, конец — уже за полночь.
      final start = DateTime.utc(2026, 10, 5, 23, 30);
      final o = occurrenceOn(
        eventId: 1,
        startsAt: start,
        endsAt: DateTime.utc(2026, 10, 6, 0, 30),
        recurrence: Recurrence.daily,
        byWeekdays: 0,
        dayUtc: day(7),
      );
      expect(o!.start, DateTime.utc(2026, 10, 7, 23, 30));
      expect(o.end, DateTime.utc(2026, 10, 8, 0, 30));
    });
  });
}
