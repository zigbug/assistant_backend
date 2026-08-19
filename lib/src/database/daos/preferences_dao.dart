import 'package:drift/drift.dart';

import '../database.dart';

// Часть для кодогенерации Drift.
part 'preferences_dao.g.dart';

/// DAO для работы с настройками (key-value хранилище).
@DriftAccessor(tables: [Preferences])
class PreferencesDao extends DatabaseAccessor<AppDatabase>
    with _$PreferencesDaoMixin {
  PreferencesDao(super.db);

  /// Получить значение настройки по ключу.
  Future<String?> get(String key) async {
    final result = await (select(preferences)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return result?.value;
  }

  /// Получить все настройки как Map.
  Future<Map<String, String>> getAll() async {
    final all = await select(preferences).get();
    return {for (final pref in all) pref.key: pref.value};
  }

  /// Установить значение настройки (upsert — создаёт или обновляет).
  Future<void> set(String key, String value) async {
    await into(preferences).insertOnConflictUpdate(
      PreferencesCompanion.insert(
        key: key,
        value: value,
      ),
    );
  }

  /// Установить несколько настроек сразу.
  Future<void> setMany(Map<String, String> prefs) async {
    await batch((batch) {
      batch.insertAllOnConflictUpdate(
        preferences,
        prefs.entries
            .map((e) => PreferencesCompanion.insert(key: e.key, value: e.value))
            .toList(),
      );
    });
  }

  /// Удалить настройку по ключу.
  Future<int> deleteByKey(String key) {
    return (delete(preferences)..where((t) => t.key.equals(key))).go();
  }

  /// Проверить, существует ли настройка.
  Future<bool> exists(String key) async {
    final result = await (select(preferences)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return result != null;
  }

  /// Получить настройку с дефолтным значением.
  Future<String> getOrDefault(String key, String defaultValue) async {
    final value = await get(key);
    return value ?? defaultValue;
  }

  /// Reactive: следить за всеми настройками.
  Stream<Map<String, String>> watchAll() {
    return select(preferences).watch().map(
          (all) => {for (final pref in all) pref.key: pref.value},
        );
  }
}