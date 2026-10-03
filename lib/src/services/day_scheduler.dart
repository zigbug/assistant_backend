/// Результат попытки поставить задачу в фиксированный слот.
class FixedPlacement {
  const FixedPlacement(this.start, this.reason);

  /// Начало слота либо null, если разместить не удалось.
  final DateTime? start;

  /// Человекочитаемая причина отказа.
  final String? reason;
}

/// Занятый интервал в течение дня — событие, перерыв или уже размещённая задача.
///
/// Интервалы хранятся в **локальном** времени: планировщик мыслит
/// категориями «09:00», «14:00», а не epoch-миллисекундами. В базу
/// уходит UTC.
typedef BusyInterval = ({DateTime start, DateTime end});

/// Задача, которую нужно куда-то положить.
class SchedulableTask {
  SchedulableTask({
    required this.refId,
    required this.durationMinutes,
    this.title = '',
    this.scheduledTime,
    this.isOverdue = false,
    this.priority = 0,
  });

  /// ID задачи — по нему возвращаем размещённый слот.
  final int refId;

  /// Название задачи. Нужно, чтобы объяснить пользователю, почему слот
  /// не достался: «пересекается с “Ревью”» полезнее, чем «занято 09:00».
  final String title;

  /// Длительность в минутах. Задачи без оценки сюда не попадают: у них
  /// нет продолжительности, а значит нет и честного слота.
  final int durationMinutes;

  /// Желаемое начало в минутах от полуночи (локальное время).
  /// null — планировщик подбирает сам.
  final int? scheduledTime;

  /// Просроченная задача: размещается в первую очередь.
  final bool isOverdue;

  /// Ранг приоритета (выше — раньше). Обычно Эйзенхауэр или срочность.
  final int priority;

  /// Слот, который подобрал планировщик. Заполняется при размещении.
  BusyInterval? slot;
}

/// Результат раскладки дня.
class DayLayout {
  DayLayout({
    required this.tasks,
    required this.unplaced,
    this.reasons = const {},
  });

  /// Размещённые задачи с проставленными слотами.
  final List<SchedulableTask> tasks;

  /// Задачи, которые не поместились: слот занят либо не хватило рабочего
  /// времени. Для них план покажет «время не назначено».
  final List<SchedulableTask> unplaced;

  /// Почему задача из [unplaced] не получила время. Ключ — [SchedulableTask.refId].
  /// Без этого пользователь видит «не поместилась» и не понимает, что
  /// конкретно мешает: он же ничего не пересекал.
  final Map<int, String> reasons;

  /// Слот задачи по её ID.
  BusyInterval? slotOf(int refId) {
    for (final task in tasks) {
      if (task.refId == refId) return task.slot;
    }
    return null;
  }
}

/// Раскладывает задачи дня по свободным слотам.
///
/// Раньше все задачи ложились в полночь своей даты, а задачи без оценки
/// времени вообще оставались без интервала — план показывал `00:00`
/// или «время не назначено» и был бесполезен. Здесь задачи
/// раскладываются последовательно: события и перерывы занимают
/// фиксированные интервалы, задачи заполняют оставшиеся окна.
class DayScheduler {
  /// Рабочий диапазон по умолчанию (локальное время).
  static const dayStartMinutes = 7 * 60; // 07:00
  static const dayEndMinutes = 23 * 60; // 23:00

  /// Разводит [tasks] по свободным окнам дня.
  ///
  /// [busy] — занятые интервалы (события). Они не двигаются: событие
  /// поставил пользователь осознанно, в отличие от задачи, которую
  /// планировщик раскладывает сам.
  ///
  /// [breaks] — интервалы, которые нельзя занимать (обед и т.п.), в минутах
  /// от полуночи. По умолчанию пусто: перерывы не выдумываются. Раньше здесь
  /// был зашит обед 12:00–13:00, из-за чего рабочий блок 09:00–14:00
  /// всегда пересекался с ним и не помещался в день. Если пользователь
  /// хочет защитить обед от задач — передай интервал сюда.
  DayLayout schedule({
    required DateTime day,
    required List<BusyInterval> busy,
    required List<SchedulableTask> tasks,
    int dayStartMinutes = DayScheduler.dayStartMinutes,
    int dayEndMinutes = DayScheduler.dayEndMinutes,
    List<({int from, int to})> breaks = const [],
  }) {
    final windowStart = atMinutes(day, dayStartMinutes);
    final windowEnd = atMinutes(day, dayEndMinutes);

    // Занятые интервалы: события + перерывы.
    //
    // События обрезаем рабочим окном: событие, начавшееся в 06:00, должно
    // блокировать от 07:00, а не от 06:00. Перерывы тоже допускаем только
    // внутри окна.
    final blocked = <BusyInterval>[
      for (final interval in busy)
        if (interval.end.isAfter(windowStart) &&
            interval.start.isBefore(windowEnd))
          (
            start: interval.start.isBefore(windowStart)
                ? windowStart
                : interval.start,
            end: interval.end.isAfter(windowEnd) ? windowEnd : interval.end,
          ),
      for (final br in breaks)
        if (br.to > br.from &&
            br.to > dayStartMinutes &&
            br.from < dayEndMinutes)
          (
            start: atMinutes(
                day, br.from < dayStartMinutes ? dayStartMinutes : br.from),
            end: atMinutes(day, br.to > dayEndMinutes ? dayEndMinutes : br.to),
          ),
    ]..sort((a, b) => a.start.compareTo(b.start));

    // Задачи с фиксированным временем идут первыми — иначе жадная
    // раскладка займёт их слот более «важной» задачей без времени.
    final ordered = [...tasks]..sort(compareTasks);

    final placed = <SchedulableTask>[];
    final unplaced = <SchedulableTask>[];
    final reasons = <int, String>{};

    // Что уже размещено — чтобы объяснить конфликт конкретной задачей.
    final placedSlots = <int, ({String title, BusyInterval slot})>{};

    for (final task in ordered) {
      final duration = Duration(minutes: task.durationMinutes);

      DateTime? start;
      String? reason;

      if (task.scheduledTime != null) {
        final attempt = _placeAtFixed(
          day: day,
          blocked: blocked,
          windowStart: windowStart,
          windowEnd: windowEnd,
          task: task,
          placedSlots: placedSlots,
        );
        start = attempt.start;
        reason = attempt.reason;
      } else {
        start = _placeFirstFit(
          blocked: blocked,
          windowStart: windowStart,
          windowEnd: windowEnd,
          duration: duration,
        );
        reason = start == null
            ? '${didNotFit}в день не осталось свободного окна '
                'на ${task.durationMinutes} мин'
            : null;
      }

      if (start == null) {
        unplaced.add(task);
        reasons[task.refId] = reason ?? 'не удалось разместить';
        continue;
      }

      final slot = (start: start, end: start.add(duration));
      task.slot = slot;
      blocked.add(slot);
      // Держим интервалы отсортированными — следующие ищутся по порядку.
      blocked.sort((a, b) => a.start.compareTo(b.start));
      placed.add(task);
      placedSlots[task.refId] = (title: task.title, slot: slot);
    }

    return DayLayout(tasks: placed, unplaced: unplaced, reasons: reasons);
  }

  /// Порядок раскладки: просроченные → фиксированное время → приоритет.
  ///
  /// Среди задач с фиксированным временем решает именно время, а не
  /// приоритет: если пользователь попросил «рабочий блок в 09:00» и
  /// «ревью в 09:30», то первым должен занять слот тот, кто попросил
  /// раньше. Иначе важная задача молча вытесняла бы менее важную из
  /// уже запрошенного часа, и пользователь не понимал бы почему.
  static int compareTasks(SchedulableTask a, SchedulableTask b) {
    if (a.isOverdue != b.isOverdue) return a.isOverdue ? -1 : 1;
    final aFixed = a.scheduledTime != null;
    final bFixed = b.scheduledTime != null;
    if (aFixed != bFixed) return aFixed ? -1 : 1;
    if (aFixed && bFixed) {
      final byTime = a.scheduledTime!.compareTo(b.scheduledTime!);
      if (byTime != 0) return byTime;
    }
    final byPriority = b.priority.compareTo(a.priority);
    if (byPriority != 0) return byPriority;
    return a.refId.compareTo(b.refId);
  }

  /// Ищет самое раннее свободное окно нужной длины.
  DateTime? _placeFirstFit({
    required List<BusyInterval> blocked,
    required DateTime windowStart,
    required DateTime windowEnd,
    required Duration duration,
  }) {
    for (final gap in freeGaps(blocked, windowStart, windowEnd)) {
      if (gap.end.difference(gap.start) >= duration) return gap.start;
    }
    return null;
  }

  /// Ставит задачу в заданное ею время, если слот свободен и влезает в день.
  ///
  /// Молча сдвигать задачу на другое время нельзя — пользователь попросил
  /// именно этот час. Вместе с отказом возвращаем [FixedPlacement.reason]:
  /// «занято 09:00» бесполезно (это и было запрошенное время), нужно назвать
  /// то, что пересеклось.
  FixedPlacement _placeAtFixed({
    required DateTime day,
    required List<BusyInterval> blocked,
    required DateTime windowStart,
    required DateTime windowEnd,
    required SchedulableTask task,
    required Map<int, ({String title, BusyInterval slot})> placedSlots,
  }) {
    final start = atMinutes(day, task.scheduledTime!);
    final end = start.add(Duration(minutes: task.durationMinutes));

    if (start.isBefore(windowStart)) {
      return FixedPlacement(
        null,
        '${didNotFit}раньше рабочего дня (${_hhmmOf(windowStart)})',
      );
    }
    if (end.isAfter(windowEnd)) {
      return FixedPlacement(
        null,
        '${didNotFit}заканчивается после рабочего дня (${_hhmmOf(windowEnd)})',
      );
    }

    for (final interval in blocked) {
      // Пересечение полуинтервалов [start, end) и [interval.start, interval.end).
      if (!start.isBefore(interval.end) || !interval.start.isBefore(end)) {
        continue;
      }
      // Пересечение нашлось — ищем, какая именно размещённая задача сюда попала,
      // чтобы назвать её пользователю.
      final owner = _ownerOf(interval, placedSlots);
      final range = '${_hhmmOf(interval.start)}-${_hhmmOf(interval.end)}';
      return FixedPlacement(
        null,
        owner == null
            ? '${didNotFit}слот занят ($range)'
            : '${didNotFit}пересекается с «$owner» ($range)',
      );
    }
    return FixedPlacement(start, null);
  }

  /// Маркер в заметке элемента плана: задача с оценкой, которая не поместилась
  /// в день. MCP по нему отличает «не поместилась» от «задача на весь день»
  /// (у которой нет оценки) — иначе обе формулировки выглядели бы одинаково,
  /// и пользователь решил бы, что всё разложено по часам.
  ///
  /// Поэтому любая причина отказа обязана начинаться с этого префикса,
  /// в нижнем регистре: MCP ищет именно такую подстроку в заметке.
  static const didNotFit = 'не поместилась: ';

  /// Название задачи, которой принадлежит интервал, либо null для событий.
  String? _ownerOf(
    BusyInterval interval,
    Map<int, ({String title, BusyInterval slot})> placedSlots,
  ) {
    for (final entry in placedSlots.entries) {
      if (entry.value.title.isEmpty) continue;
      final slot = entry.value.slot;
      if (slot.start == interval.start && slot.end == interval.end) {
        return entry.value.title;
      }
    }
    return null;
  }

  /// Минуты от полуночи в локальном виде `09:30`.
  String _hhmmOf(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Свободные промежутки между занятыми интервалами внутри окна.
  List<BusyInterval> freeGaps(
    List<BusyInterval> blocked,
    DateTime windowStart,
    DateTime windowEnd,
  ) {
    final gaps = <BusyInterval>[];
    var cursor = windowStart;

    for (final interval in blocked) {
      // Интервал целиком до окна — пропускаем.
      if (!interval.start.isAfter(cursor)) continue;
      gaps.add((start: cursor, end: interval.start));
      cursor = interval.end.isAfter(cursor) ? interval.end : cursor;
    }

    if (cursor.isBefore(windowEnd)) {
      gaps.add((start: cursor, end: windowEnd));
    }
    return gaps;
  }

  /// Локальное время [day] на [minutes] минут от полуночи.
  static DateTime atMinutes(DateTime day, int minutes) {
    return DateTime(
      day.year,
      day.month,
      day.day,
      minutes ~/ 60,
      minutes % 60,
    );
  }
}
