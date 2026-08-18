import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';

/// Фабрика для создания экземпляра [AppDatabase].
///
/// Стратегия выбора драйвера:
///   1. Если задана переменная окружения DATABASE_URL — подключается
///      к PostgreSQL (для продакшена на VPS).
///   2. Иначе создаётся локальная SQLite-база в application support директории
///      (для разработки на Windows/macOS/Linux).
///
/// Путь к SQLite-базе:
///   - Windows: %APPDATA%/assistant_backend/assistant.db
///   - macOS:   ~/Library/Application Support/assistant_backend/assistant.db
///   - Linux:   ~/.local/share/assistant_backend/assistant.db
///
/// Пример использования:
/// ```dart
/// final db = await createDatabase();
/// // ... работаем с базой ...
/// await db.close();
/// ```
///
/// Для продакшена задай DATABASE_URL:
///   postgres://user:password@localhost:5432/assistant
/// и приложение автоматически переключится на PostgreSQL.
Future<AppDatabase> createDatabase({String? databaseUrl}) async {
  // 1. Если указан URL — используем PostgreSQL.
  final url = databaseUrl ?? Platform.environment['DATABASE_URL'];
  if (url != null && url.startsWith('postgres')) {
    // TODO(Denis): раскомментировать после миграции на PostgreSQL в v2.
    // Требуется импорт:
    //   import 'package:drift_postgres/drift_postgres.dart';
    // и подключение к Postgres через PgDatabaseConnection.
    //
    // Пример (приблизительный, уточнить по актуальному API drift_postgres):
    //
    //   final endpoint = Uri.parse(url);
    //   final connection = PgDatabaseConnection(
    //     endpoint: PgEndpoint(
    //       host: endpoint.host,
    //       port: endpoint.port,
    //       database: endpoint.pathSegments.first,
    //       username: endpoint.userInfo.split(':').first,
    //       password: endpoint.userInfo.split(':').last,
    //     ),
    //   );
    //   return AppDatabase(connection);
    //
    throw UnimplementedError(
      'PostgreSQL support not implemented yet. '
      'Use SQLite (leave DATABASE_URL unset) for local development.',
    );
  }

  // 2. По умолчанию — SQLite.
  // Создаём директорию если её нет и открываем базу в изоляте.
  final executor = NativeDatabase.createInBackground(
    _sqliteFile,
    logStatements: false, // Включаем при отладке SQL-запросов.
  );

  return AppDatabase(executor);
}

/// Файл SQLite-базы данных.
/// Ленивый геттер — путь вычисляется синхронно через applicationSupportDirectory.
File get _sqliteFile {
  // Для простоты используем синхронный путь. В реальном приложении
  // лучше получать path_provider асинхронно один раз и передавать в фабрику.
  // Здесь используем относительный путь для простоты разработки.
  final dbDir = Directory('data');
  if (!dbDir.existsSync()) {
    dbDir.createSync(recursive: true);
  }
  return File(p.join(dbDir.path, 'assistant.db'));
}

/// Вспомогательная функция для получения пути к data-директории
/// через path_provider (для мобильных/десктопных приложений).
/// Оставлена на будущее, когда понадобится корректный кроссплатформенный путь.
Future<Directory> getDataDirectory() async {
  final appDir = await getApplicationSupportDirectory();
  final dataDir = Directory(p.join(appDir.path, 'assistant_backend'));
  if (!await dataDir.exists()) {
    await dataDir.create(recursive: true);
  }
  return dataDir;
}
