import 'package:drift/drift.dart';

/// Типы заметок.
enum NoteKind {
  idea,    // Идея (может стать задачей или проектом)
  thought, // Мысль, наблюдение
  note,    // Обычная заметка
}

/// Статусы заметок (жизненный цикл).
enum NoteStatus {
  inbox,    // Попадёт сюда при capture, ждёт ревью
  promoted, // Превращена в задачу/проект
  archived, // В архив (не удалено, но не показывается в активных)
}

/// Заметки — инбокс для «идей, мыслей, заметок».
/// Главная идея: быстрый capture из Flutter-приложения,
/// потом на еженедельном ревью AI предлагает превратить их в задачи.
class Notes extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Содержимое заметки (markdown поддерживается на фронте).
  TextColumn get content => text()();

  /// Тип заметки (см. NoteKind).
  // Constant принимает SQL-значение (строку), а не Dart-enum.
  TextColumn get kind => textEnum<NoteKind>()
      .withDefault(const Constant('note'))();

  /// Статус заметки (см. NoteStatus).
  TextColumn get status => textEnum<NoteStatus>()
      .withDefault(const Constant('inbox'))();

  /// Ссылка на задачу, в которую заметка превратилась (nullable).
  /// Не используем FK, чтобы избежать циклических зависимостей.
  IntColumn get linkedTaskId => integer().nullable()();

  /// Теги через запятую (например "flutter,идея_приложения").
  /// В v2 можно будет сделать отдельную таблицу tags + M2M.
  TextColumn get tags => text().nullable()();

  /// Дата и время создания.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
}
