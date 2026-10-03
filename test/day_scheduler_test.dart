import 'package:assistant_backend/src/services/day_scheduler.dart';
import 'package:test/test.dart';

/// Локальный полдень — тесты не зависят от часового пояса машины.
final day = DateTime(2026, 10, 7);

DateTime at(int minutes) => DayScheduler.atMinutes(day, minutes);

String hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

void main() {
  group('рабочий день', () {
    test('блок 09:00 на 300 минут занимает 09:00-14:00 без обедов', () {
      final layout = DayScheduler().schedule(
        day: day,
        busy: const [],
        tasks: [
          SchedulableTask(
              refId: 1,
              title: 'Блок',
              durationMinutes: 300,
              scheduledTime: 9 * 60),
        ],
      );

      expect(layout.unplaced, isEmpty);
      final slot = layout.slotOf(1)!;
      expect(hhmm(slot.start), '09:00');
      expect(hhmm(slot.end), '14:00');
    });

    test('задача без времени встаёт в первый свободный gap', () {
      final layout = DayScheduler().schedule(
        day: day,
        busy: [(start: at(9 * 60), end: at(10 * 60))],
        tasks: [
          SchedulableTask(refId: 1, title: 'Звонок', durationMinutes: 30)
        ],
      );

      final slot = layout.slotOf(1)!;
      expect(hhmm(slot.start), '07:00');
      expect(hhmm(slot.end), '07:30');
    });

    test('задача вытесняет за событие в рабочее окно', () {
      final layout = DayScheduler().schedule(
        day: day,
        busy: [(start: at(6 * 60), end: at(8 * 60))],
        tasks: [SchedulableTask(refId: 1, durationMinutes: 60)],
      );

      expect(hhmm(layout.slotOf(1)!.start), '07:00');
    });
  });

  group('мягкие события', () {
    test('мягкое событие не блокирует, потому что его не передают в busy', () {
      // Мягкое событие (`canOverlap`) отсекает сервер, в планировщик оно не
      // доходит: в `busy` попадают только жёсткие блокирующие интервалы.
      // Проверяем этот контракт — блок 09:00-14:00 встаёт в слот, хотя
      // внутри него проходит мягкий звонок 10:00-10:15.
      final layout = DayScheduler().schedule(
        day: day,
        busy: const [],
        tasks: [
          SchedulableTask(
              refId: 1,
              title: 'Блок',
              durationMinutes: 300,
              scheduledTime: 9 * 60),
        ],
      );

      expect(layout.unplaced, isEmpty);
      expect(hhmm(layout.slotOf(1)!.start), '09:00');
      expect(hhmm(layout.slotOf(1)!.end), '14:00');
    });

    test('жёсткое событие внутри блока вытесняет его', () {
      final layout = DayScheduler().schedule(
        day: day,
        busy: [(start: at(10 * 60), end: at(10 * 60 + 15))],
        tasks: [
          SchedulableTask(
              refId: 1,
              title: 'Блок',
              durationMinutes: 300,
              scheduledTime: 9 * 60),
        ],
      );

      expect(layout.slotOf(1), isNull);
      expect(layout.reasons[1], contains('слот занят (10:00-10:15)'));
    });
  });

  group('конфликты', () {
    test('жёсткое событие вытесняет задачу, но не сдвигает её', () {
      final layout = DayScheduler().schedule(
        day: day,
        busy: [(start: at(9 * 60), end: at(10 * 60))],
        tasks: [
          SchedulableTask(
              refId: 1,
              title: 'Блок',
              durationMinutes: 120,
              scheduledTime: 9 * 60),
        ],
      );

      expect(layout.slotOf(1), isNull);
      expect(layout.unplaced.single.refId, 1);
      expect(layout.reasons[1], contains('слот занят (09:00-10:00)'));
    });

    test('при конфликте двух задач с временем побеждает более ранний слот', () {
      final layout = DayScheduler().schedule(
        day: day,
        busy: const [],
        tasks: [
          SchedulableTask(
              refId: 1,
              title: 'Блок',
              durationMinutes: 300,
              scheduledTime: 9 * 60,
              priority: 3),
          SchedulableTask(
              refId: 2,
              title: 'Ревью',
              durationMinutes: 45,
              scheduledTime: 9 * 60 + 30,
              priority: 5),
        ],
      );

      expect(hhmm(layout.slotOf(1)!.start), '09:00');
      expect(layout.slotOf(2), isNull);
      expect(layout.reasons[2],
          'не поместилась: пересекается с «Блок» (09:00-14:00)');
    });

    test('задача вне рабочего окна объясняет причину', () {
      final layout = DayScheduler().schedule(
        day: day,
        busy: const [],
        tasks: [
          SchedulableTask(refId: 1, durationMinutes: 60, scheduledTime: 6 * 60),
          SchedulableTask(
              refId: 2, durationMinutes: 60, scheduledTime: 22 * 60 + 30),
        ],
      );

      expect(layout.reasons[1], contains('раньше рабочего дня'));
      expect(layout.reasons[2], contains('после рабочего дня'));
    });
  });

  group('размер', () {
    test('задача больше любого свободного окна остаётся без времени', () {
      final layout = DayScheduler().schedule(
        day: day,
        busy: [(start: at(7 * 60), end: at(8 * 60))],
        tasks: [
          SchedulableTask(
              refId: 1,
              title: 'Блок',
              durationMinutes: 300,
              scheduledTime: 9 * 60),
          SchedulableTask(refId: 2, title: 'Огромная', durationMinutes: 600),
        ],
      );

      expect(layout.slotOf(2), isNull);
      expect(layout.reasons[2],
          'не поместилась: в день не осталось свободного окна на 600 мин');
    });

    test('перерыв режет окно, если его явно передали', () {
      final layout = DayScheduler().schedule(
        day: day,
        busy: const [],
        breaks: [(from: 12 * 60, to: 13 * 60)],
        tasks: [
          SchedulableTask(
              refId: 1,
              title: 'Блок',
              durationMinutes: 300,
              scheduledTime: 9 * 60),
        ],
      );

      expect(layout.unplaced.single.refId, 1);
      expect(layout.reasons[1], contains('слот занят'));
    });
  });

  group('порядок', () {
    test('просроченные идут первыми и получают время до остальных', () {
      final layout = DayScheduler().schedule(
        day: day,
        busy: const [],
        tasks: [
          SchedulableTask(
              refId: 1,
              title: 'Обычная',
              durationMinutes: 30,
              scheduledTime: 9 * 60),
          SchedulableTask(
              refId: 2,
              title: 'Просроченная',
              durationMinutes: 60,
              isOverdue: true),
        ],
      );

      expect(hhmm(layout.slotOf(2)!.start), '07:00');
    });

    test('каждая причина отказа содержит маркер didNotFit для MCP', () {
      // MCP определяет «не поместилась» по подстроке в заметке элемента
      // плана. Потеря маркера молча превратит честное сообщение
      // «пересекается с “Блок”» в «задача на весь день» — то есть
      // пользователю скажут, что у задачи нет длительности, хотя
      // длительность есть и дело в конфликте.
      final layout = DayScheduler().schedule(
        day: day,
        busy: [(start: at(9 * 60), end: at(10 * 60))],
        tasks: [
          SchedulableTask(
              refId: 1,
              title: 'Пересекается',
              durationMinutes: 60,
              scheduledTime: 9 * 60),
          SchedulableTask(
              refId: 2,
              title: 'Слишком ранняя',
              durationMinutes: 60,
              scheduledTime: 5 * 60),
          SchedulableTask(
              refId: 3,
              title: 'Слишком поздняя',
              durationMinutes: 60,
              scheduledTime: 23 * 60),
          SchedulableTask(refId: 4, title: 'Не влезает', durationMinutes: 6000),
        ],
      );

      expect(layout.unplaced, hasLength(4));
      for (final entry in layout.reasons.entries) {
        expect(entry.value, startsWith(DayScheduler.didNotFit),
            reason: 'задача ${entry.key}: ${entry.value}');
        expect(entry.value, contains(DayScheduler.didNotFit));
      }
    });
  });
}
