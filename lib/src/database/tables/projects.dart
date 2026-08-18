import 'package:drift/drift.dart';

/// Проекты — это «сферы жизни», к которым относятся задачи.
/// Например: «Работа», «Пет-проекты», «Здоровье», «Учёба».
/// Задача может быть привязана к проекту или существовать сама по себе.
class Projects extends Table {
  /// Уникальный идентификатор проекта (автоинкремент).
  IntColumn get id => integer().autoIncrement()();

  /// Название проекта (обязательное, до 100 символов).
  TextColumn get name => text().withLength(min: 1, max: 100)();

  /// Цвет проекта в hex-формате (например #FF5733) для визуального отображения в UI.
  /// Необязательное поле — UI может использовать дефолтный цвет.
  TextColumn get color => text().nullable()();

  /// Флаг архивации. Архивированные проекты не показываются в активных списках,
  /// но их данные и задачи сохраняются для истории.
  BoolColumn get isArchived =>
      boolean().withDefault(const Constant(false))();

  /// Дата и время создания проекта.
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
}
