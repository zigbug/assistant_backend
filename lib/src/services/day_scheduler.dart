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
    this.scheduledTime,
    this.isOverdue = false,
    this.priority = 0,
  });

  /// ID задачи — по нему возвращаем размещённый слот.
  final int refId;

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
  DayLayout({required this.tasks, required this.unplaced});

  /// Размещённые задачи с проставленными слотами.
  final List<SchedulableTask> tasks;

  /// Задачи, которые не поместились: слот занят либо не хватило рабочего
  /// времени. Для них план покажет «время не назначено».
  final List<SchedulableTask> unplaced;

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

  /// Перерывы, которые нельзя занимать (локальное время).
  /// Обед — между рабочими блоками 09:00–14:00 и 15:00–18:00.
  static const breaks = <({int from, int to})>[
    (from: 12 * 60, to: 13 * 60), // 12:00–13:00
  ];

  /// Разводит [tasks] по свободным окнам дня.
  ///
  /// [busy] — занятые интервалы (события). Они не двигаются: событие
  /// поставил пользователь осознанно, в отличие от задачи, которую
  /// планировщик раскладывает сам.
  DayLayout schedule({
    required DateTime day,
    required List<BusyInterval> busy,
    required List<SchedulableTask> tasks,
    int dayStartMinutes = DayScheduler.dayStartMinutes,
    int dayEndMinutes = DayScheduler.dayEndMinutes,
  }) {
    final windowStart = atMinutes(day, dayStartMinutes);
    final windowEnd = atMinutes(day, dayEndMinutes);

    // Занятые интервалы: события + перерывы, обрезанные рабочим окном.
    final blocked = <BusyInterval>[
      for (final interval in busy)
        if (interval.end.isAfter(windowStart) &&
            interval.start.isBefore(windowEnd))
          interval,
      for (final br in breaks)
        (start: atMinutes(day, br.from), end: atMinutes(day, br.to)),
    ]..sort((a, b) => a.start.compareTo(b.start));

    // Задачи с фиксированным временем идут первыми — иначе жадная
    // раскладка займёт их слот более «важной» задачей без времени.
    final ordered = [...tasks]..sort(compareTasks);

    final placed = <SchedulableTask>[];
    final unplaced = <SchedulableTask>[];

    for (final task in ordered) {
      final duration = Duration(minutes: task.durationMinutes);

      final DateTime? start = task.scheduledTime != null
          ? _placeAtFixed(
              day: day,
              blocked: blocked,
              windowStart: windowStart,
              windowEnd: windowEnd,
              task: task,
            )
          : _placeFirstFit(
              blocked: blocked,
              windowStart: windowStart,
              windowEnd: windowEnd,
              duration: duration,
            );

      if (start == null) {
        unplaced.add(task);
        continue;
      }

      final slot = (start: start, end: start.add(duration));
      task.slot = slot;
      blocked.add(slot);
      // Держим интервалы отсортированными — следующие ищутся по порядку.
      blocked.sort((a, b) => a.start.compareTo(b.start));
      placed.add(task);
    }

    return DayLayout(tasks: placed, unplaced: unplaced);
  }

  /// Порядок раскладки: просроченные → фиксированное время → приоритет.
  static int compareTasks(SchedulableTask a, SchedulableTask b) {
    if (a.isOverdue != b.isOverdue) return a.isOverdue ? -1 : 1;
    if ((a.scheduledTime != null) != (b.scheduledTime != null)) {
      return a.scheduledTime != null ? -1 : 1;
    }
    final byPriority = b.priority.compareTo(a.priority);
    if (byPriority != 0) return byPriority;
    if (a.scheduledTime != null && b.scheduledTime != null) {
      final byTime = a.scheduledTime!.compareTo(b.scheduledTime!);
      if (byTime != 0) return byTime;
    }
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
  /// Возвращает null, если слот занят или выходит за рабочий диапазон:
  /// молча сдвигать задачу на другое время нельзя — пользователь
  /// попросил именно этот час.
  DateTime? _placeAtFixed({
    required DateTime day,
    required List<BusyInterval> blocked,
    required DateTime windowStart,
    required DateTime windowEnd,
    required SchedulableTask task,
  }) {
    final start = atMinutes(day, task.scheduledTime!);
    final end = start.add(Duration(minutes: task.durationMinutes));

    if (start.isBefore(windowStart) || end.isAfter(windowEnd)) return null;

    for (final interval in blocked) {
      // Пересечение полуинтервалов [start, end) и [interval.start, interval.end).
      if (start.isBefore(interval.end) && interval.start.isBefore(end)) {
        return null;
      }
    }
    return start;
  }

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
