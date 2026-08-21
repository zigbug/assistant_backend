import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

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
  int get schemaVersion => 2;

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
        // v2 (21 августа 2026): Добавлены статусы inProgress и cancelled
        // в enum PlanItemStatus. Поскольку enum хранится как textEnum,
        // существующие записи не требуют миграции — новые значения
        // становятся доступны автоматически.
        if (from < 2) {
          // Пустая миграция — фиксируем версию в истории.
          // В будущем здесь могут появиться реальные ALTER TABLE.
        }
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

/// Возвращает директорию для хранения данных приложения (кроссплатформенно).
///
/// - Windows: `%APPDATA%/assistant_backend` (например, `C:\Users\Denis\AppData\Roaming\assistant_backend`)
/// - Linux: `$HOME/.local/share/assistant_backend`
/// - macOS: `$HOME/Library/Application Support/assistant_backend`
Directory _getDataDirectory() {
  final String homePath;

  if (Platform.isWindows) {
    // На Windows используем %APPDATA% (Roaming)
    homePath = Platform.environment['APPDATA'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return Directory(p.join(homePath, 'assistant_backend'));
  } else if (Platform.isMacOS) {
    // macOS: ~/Library/Application Support/assistant_backend
    homePath = Platform.environment['HOME'] ?? '~';
    return Directory(p.join(
        homePath, 'Library', 'Application Support', 'assistant_backend'));
  } else {
    // Linux: ~/.local/share/assistant_backend (XDG стандарт)
    homePath = Platform.environment['HOME'] ?? '~';
    return Directory(p.join(homePath, '.local', 'share', 'assistant_backend'));
  }
}

/// Фабричная функция для создания экземпляра базы данных.
///
/// Использует SQLite для локальной разработки. Файл базы данных создаётся
/// в директории приложения (например, на Windows: %APPDATA%/assistant_backend).
///
/// Для тестирования можно передать `inMemory: true`, чтобы база создавалась
/// в оперативной памяти и удалялась после закрытия.
AppDatabase createDatabase({bool inMemory = false}) {
  if (inMemory) {
    // In-memory база для тестов
    return AppDatabase(NativeDatabase.memory());
  }

  // Создаём LazyDatabase, чтобы база открывалась лениво (при первом запросе)
  return AppDatabase(
    LazyDatabase(() async {
      // Определяем директорию для хранения файла БД
      final dbFolder = _getDataDirectory();
      final file = File(p.join(dbFolder.path, 'assistant.db'));

      print('Database file location: ${file.path}');

      // Возвращаем NativeDatabase с путём к файлу
      return NativeDatabase.createInBackground(file);
    }),
  );
}
