import 'package:drift/drift.dart';
import 'projects.dart';

/// Статусы задачи. Логика переходов:
///   backlog → todo → in_progress → done
///                    ↘ waiting (ждём ответа/события)
///   любой статус → cancelled (отменено)
///   done → todo (если переоткрыли)
enum TaskStatus {
  backlog, // Идея, ещё не в работе
  todo, // В бэклоге, ждёт планирования
  inProgress, // Сейчас в работе
  waiting, // Ждём кого-то/чего-то (делегировано, ждём ответа)
  done, // Выполнено
  cancelled, // Отменено
}

/// Задачи — основная сущность личного ассистента.
/// Каждая задача может быть привязана к проекту, иметь дедлайн,
/// оценку времени и матрицу Эйзенхауэра (важность × срочность).
@DataClassName('Task')
class Tasks extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Название задачи (краткое описание, до 200 символов).
  TextColumn get title => text().withLength(min: 1, max: 200)();

  /// Подробное описание задачи (markdown поддерживается на фронте).
  TextColumn get description => text().nullable()();

  /// Ссылка на проект (nullable — задача может быть без проекта).
  IntColumn get projectId => integer().nullable().references(Projects, #id)();

  /// Текущий статус задачи (см. TaskStatus).
  // Constant принимает SQL-значение (строку, совпадающую с enum.name),
  // а не сам Dart-enum.
  TextColumn get status =>
      textEnum<TaskStatus>().withDefault(const Constant('todo'))();

  /// Важность по матрице Эйзенхауэра (1..4):
  ///   1 — неважно, 2 — средне, 3 — важно, 4 — критично.
  /// Используется AI при приоритизации плана дня.
  /// Диапазон валидируется в DAO (CHECK-констрейнт убран, чтобы
  /// избежать рекурсивных геттеров в Drift-таблицах).
  IntColumn get importance => integer().withDefault(const Constant(2))();

  /// Срочность по матрице Эйзенхауэра (1..4):
  ///   1 — не срочно, 2 — скоро, 3 — срочно, 4 — прямо сейчас.
  IntColumn get urgency => integer().withDefault(const Constant(2))();

  /// Жёсткий дедлайн (дата+время). Если пропустить — AI не считает задачу просроченной.
  DateTimeColumn get deadline => dateTime().nullable()();

  /// День, на который задача запланирована (для time blocking).
  /// Используется при генерации плана дня.
  DateTimeColumn get scheduledDate => dateTime().nullable()();

  /// Оценка времени выполнения в минутах.
  /// AI сравнивает с фактом и корректирует будущие оценки через таблицу ai_lessons.
  IntColumn get estimatedMinutes => integer().nullable()();

  /// Фактически затраченное время (минуты).
  /// Суммируется из time_logs (v2) или проставляется вручную.
  IntColumn get actualMinutes => integer().withDefault(const Constant(0))();

  /// Когда задача была создана.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// Когда задача была завершена (для статуса done).
  /// Nullable, т.к. задача ещё может быть в работе.
  DateTimeColumn get completedAt => dateTime().nullable()();
}
