/// Контекст времени, который возвращается AI/MCP, чтобы клиент понимал,
/// в каком моменте времени сейчас находится сервер.
///
/// Хранение дат в БД — UTC (см. ROADMAP). Здесь мы даём ИИ:
///   - serverTimeUtc   — текущий момент в UTC (всегда);
///   - serverTimeLocal — текущий момент в часовом поясе пользователя
///                       (если пояс известен и имеет фиксированный offset);
///   - timezone        — имя пояса из Preferences (по умолчанию Europe/Moscow);
///   - utcOffsetMinutes— смещение от UTC в минутах (null, если неизвестно).
///
/// Смещения российских поясов фиксированы (в РФ отмена сезонного времени
/// с 2014 года), поэтому здесь не нужна полная tz-база. Для остальных поясов
/// можно явно задать смещение через preference `utc_offset_minutes`.
class TimeContext {
  const TimeContext({
    required this.serverTimeUtc,
    required this.timezone,
    this.utcOffsetMinutes,
  });

  /// Текущий момент в UTC.
  final DateTime serverTimeUtc;

  /// Имя часового пояса из настроек (например, "Europe/Moscow").
  final String timezone;

  /// Смещение от UTC в минутах. null — если пояс не определён.
  final int? utcOffsetMinutes;

  /// Текущий момент в местном времени пользователя.
  DateTime get serverTimeLocal {
    final offset = utcOffsetMinutes ?? 0;
    return serverTimeUtc.add(Duration(minutes: offset));
  }

  bool get hasOffset => utcOffsetMinutes != null;

  Map<String, dynamic> toJson() => {
        'serverTimeUtc': serverTimeUtc.toIso8601String(),
        'serverTimeLocal': serverTimeLocal.toIso8601String(),
        'timezone': timezone,
        'utcOffsetMinutes': utcOffsetMinutes,
      };
}

/// Строит [TimeContext] по имени пояса из Preferences.
///
/// [explicitOffsetMinutes] — необязательный явный offset из preference
/// `utc_offset_minutes`. Приоритет: явный offset > известный пояс > неизвестно.
TimeContext buildTimeContext(DateTime now, String? timezoneName,
    {int? explicitOffsetMinutes}) {
  final utc = now.toUtc();
  final tz = timezoneName == null || timezoneName.trim().isEmpty
      ? 'Europe/Moscow'
      : timezoneName.trim();

  int? offset;
  if (explicitOffsetMinutes != null) {
    offset = explicitOffsetMinutes;
  } else {
    offset = russianTimezoneOffset(tz) ?? parseUtcOffset(tz);
  }

  return TimeContext(
    serverTimeUtc: utc,
    timezone: tz,
    utcOffsetMinutes: offset,
  );
}

/// Смещение для известных российских поясов (без сезонного перевода часов).
int? russianTimezoneOffset(String tz) {
  const offsets = <String, int>{
    'Europe/Kaliningrad': 120,
    'Europe/Moscow': 180,
    'Europe/Simferopol': 180,
    'Europe/Samara': 240,
    'Asia/Yekaterinburg': 300,
    'Asia/Omsk': 360,
    'Asia/Novosibirsk': 420,
    'Asia/Krasnoyarsk': 420,
    'Asia/Irkutsk': 480,
    'Asia/Yakutsk': 540,
    'Asia/Vladivostok': 600,
    'Asia/Srednekolymsk': 660,
    'Asia/Magadan': 660,
    'Asia/Kamchatka': 720,
    'Asia/Anadyr': 720,
  };
  return offsets[tz];
}

/// Распознаёт строки вида "UTC", "UTC+3", "UTC-2:30", "GMT+1".
int? parseUtcOffset(String value) {
  final normalized = value.trim().toUpperCase().replaceAll(' ', '');
  final match = RegExp(r'^(?:UTC|GMT)([+-]\d{1,2}(?::?\d{2})?)?$')
      .firstMatch(normalized);
  if (match == null) return null;
  final group = match.group(1);
  if (group == null || group.isEmpty) return 0;

  final signGroup = RegExp(r'([+-])(\d{1,2})(?::?(\d{2}))?').firstMatch(group)!;
  final sign = signGroup.group(1) == '-' ? -1 : 1;
  final hours = int.parse(signGroup.group(2)!);
  final minutes = signGroup.group(3) == null ? 0 : int.parse(signGroup.group(3)!);
  return sign * (hours * 60 + minutes);
}