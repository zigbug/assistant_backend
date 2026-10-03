import 'package:assistant_backend/src/services/time_context.dart';
import 'package:test/test.dart';

void main() {
  // Один и тот же момент: 21:42:56Z. В Москве это уже следующий день, 00:42.
  final utc = DateTime.utc(2026, 10, 3, 21, 42, 56);

  group('serverTimeLocal', () {
    test('московское время идёт с явным смещением, а не с Z', () {
      final ctx = buildTimeContext(utc, 'Europe/Moscow');

      // Раньше здесь было `...Z`, и строка утверждала бы «00:42 по UTC»,
      // хотя UTC — 21:42 предыдущего дня.
      expect(ctx.serverTimeLocalIso, '2026-10-04T00:42:56.000+03:00');
      expect(ctx.serverTimeLocalIso, isNot(contains('Z')));
    });

    test('разбор строки даёт тот же момент, а стенные часы — местные', () {
      final ctx = buildTimeContext(utc, 'Europe/Moscow');
      final iso = ctx.serverTimeLocalIso!;

      // Dart нормализует разобранное смещение в UTC — это и доказывает, что
      // строка однозначна: парсер получает ровно тот же момент.
      expect(DateTime.parse(iso).toUtc(), utc);

      // Написанные стенные часы — местные: следующий день, 00:42.
      expect(iso, startsWith('2026-10-04T00:42:56'));
      expect(iso, endsWith('+03:00'));

      // Строка со старым суффиксом «Z» означала бы другой момент — на 3 часа
      // позже настоящего. Именно это и было причиной ошибки.
      final wrong = DateTime.parse('2026-10-04T00:42:56Z').toUtc();
      expect(wrong.difference(utc), const Duration(hours: 3));
    });

    test('неизвестное смещение даёт null, а не ложное UTC', () {
      final ctx = buildTimeContext(utc, 'Not/AZone');

      expect(ctx.utcOffsetMinutes, isNull);
      expect(ctx.serverTimeLocalIso, isNull);
      expect(ctx.toJson()['serverTimeLocal'], isNull);
    });

    test(' отрицательное смещение даёт знак минус', () {
      final ctx = buildTimeContext(utc, 'America/New_York',
          explicitOffsetMinutes: -300);

      expect(ctx.serverTimeLocalIso, '2026-10-03T16:42:56.000-05:00');
    });

    test('смещение с полчаса выводится как -05:30', () {
      final ctx = buildTimeContext(utc, 'X', explicitOffsetMinutes: -330);

      expect(ctx.serverTimeLocalIso, endsWith('-05:30'));
    });

    test('нулевое смещение — честный +00:00', () {
      final ctx = buildTimeContext(utc, 'UTC');

      expect(ctx.utcOffsetMinutes, 0);
      expect(ctx.serverTimeLocalIso, '2026-10-03T21:42:56.000+00:00');
    });
  });

  group('buildTimeContext', () {
    test('пустой пояс падает в московский, а не в null', () {
      expect(buildTimeContext(utc, '  ').utcOffsetMinutes, 180);
      expect(buildTimeContext(utc, null).timezone, 'Europe/Moscow');
    });

    test('явное смещение приоритетнее распознавания пояса', () {
      final ctx =
          buildTimeContext(utc, 'Europe/Moscow', explicitOffsetMinutes: 60);

      expect(ctx.serverTimeLocalIso, endsWith('+01:00'));
      expect(ctx.timezone, 'Europe/Moscow');
    });
  });

  group('смещения поясов', () {
    test('российские пояса без сезонного перевода', () {
      expect(russianTimezoneOffset('Europe/Kaliningrad'), 120);
      expect(russianTimezoneOffset('Europe/Moscow'), 180);
      expect(russianTimezoneOffset('Asia/Yekaterinburg'), 300);
      expect(russianTimezoneOffset('Asia/Kamchatka'), 720);
      expect(russianTimezoneOffset('Europe/London'), isNull);
    });

    test('разбираются строки вида UTC+3, UTC-02:30, GMT+1', () {
      expect(parseUtcOffset('UTC'), 0);
      expect(parseUtcOffset('UTC+3'), 180);
      expect(parseUtcOffset('UTC+03:00'), 180);
      expect(parseUtcOffset('utc -02:30'), -150);
      expect(parseUtcOffset('GMT+1'), 60);
      expect(parseUtcOffset('Europe/Moscow'), isNull);
    });
  });
}
