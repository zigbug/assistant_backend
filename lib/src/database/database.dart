import 'package:drift/drift.dart';

import 'daos/ai_lessons_dao.dart';
import 'daos/daily_plans_dao.dart';
import 'daos/events_dao.dart';
import 'daos/notes_dao.dart';
import 'daos/preferences_dao.dart';
import 'daos/projects_dao.dart';
import 'daos/tasks_dao.dart';
import 'tables/ai_lessons.dart';
import 'tables/daily_plan_items.dart';
import 'tables/daily_plans.dart';
import 'tables/events.dart';
import 'tables/notes.dart';
import 'tables/preferences.dart';
import 'tables/projects.dart';
import 'tables/tasks.dart';

// Реэкспортируем все таблицы и enum-ы, чтобы клиенты базы данных
// могли импортировать один файл и иметь доступ ко всему API.
export 'tables/ai_lessons.dart';
export 'tables/daily_plan_items.dart';
export 'tables/daily_plans.dart';
export 'tables/events.dart';
export 'tables/notes.dart';
export 'tables/preferences.dart';
export 'tables/projects.dart';
export 'tables/tasks.dart';

// Часть для кодогенерации Drift.
// Этот файл создаётся автоматически через `dart run build_runner build`.
// НЕ РЕДАКТИРУЙТЕ ЕГО ВРУЧНУЮ — изменения будут перезаписаны.
part 'database.g.dart';

/// Главная точка входа для работы с базой данных.
///
/// Используется как DI-контейнер: создаётся один раз на всё приложение
/// (например в main()) и передаётся в репозитории/сервисы.
///
/// Пример использования:
/// ```dart
/// final db = createDatabase();
///
/// // Работа с задачами
/// final tasks = await db.tasksDao.getActive();
/// await db.tasksDao.complete(42);
///
/// // Работа с планом дня
/// final today = DateTime.now();
/// final plan = await db.dailyPlansDao.getOrCreateForDate(today);
///
/// // Работа с настройками
/// final workStart = await db.preferencesDao.get('work_start');
///
/// await db.close();
/// ```
@DriftDatabase(
  tables: [
    Projects,
    Tasks,
    Events,
    DailyPlans,
    DailyPlanItems,
    Preferences,
    Notes,
    AiLessons,
  ],
  daos: [
    ProjectsDao,
    TasksDao,
    EventsDao,
    DailyPlansDao,
    NotesDao,
    PreferencesDao,
    AiLessonsDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// Версия схемы. При изменении таблиц — увеличиваем и реализуем migration.
  @override
  int get schemaVersion => 1;

  /// Стратегия миграций по умолчанию — пересоздавать базу при изменении схемы.
  /// Для production это опасно — нужно будет написать onUpgrade вручную.
  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        // Создаём все таблицы и индексы при первом запуске.
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // TODO(Denis): при увеличении schemaVersion написать миграции здесь.
        // Например:
        //   if (from < 2) { await m.addColumn(tasks, tasks.newColumn); }
      },
      beforeOpen: (details) async {
        // Опциональные действия перед открытием (например включить WAL для SQLite).
        if (details.wasCreated) {
          // Можно засеять таблицу preferences дефолтными значениями.
          await _seedDefaultPreferences();
        }
      },
    );
  }

  /// Записывает дефолтные предпочтения при первом создании базы.
  /// Значения можно будет изменить через эндпоинт /api/v1/preferences.
  Future<void> _seedDefaultPreferences() async {
    final defaults = <String, String>{
      'work_start': '09:00',
      'work_end': '19:00',
      'lunch_start': '13:00',
      'lunch_end': '14:00',
      'peak_hours': 'morning',
      'no_schedule_after': '22:00',
      'timezone': 'Europe/Moscow',
      'notify_morning': 'true',
      'notify_evening': 'true',
    };

    for (final entry in defaults.entries) {
      // insert требует обычные String (non-nullable), без Value.
      await into(preferences).insertOnConflictUpdate(
        PreferencesCompanion.insert(
          key: entry.key,
          value: entry.value,
        ),
      );
    }
  }
}
