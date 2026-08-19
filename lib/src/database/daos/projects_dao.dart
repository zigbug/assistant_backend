import 'package:drift/drift.dart';

import '../database.dart';

part 'projects_dao.g.dart';

/// DAO для работы с проектами
@DriftAccessor(tables: [Projects])
class ProjectsDao extends DatabaseAccessor<AppDatabase>
    with _$ProjectsDaoMixin {
  ProjectsDao(super.db);

  /// Получить все активные проекты
  Future<List<Project>> getAllActive() async {
    return await (select(projects)..where((t) => t.isArchived.equals(false)))
        .get();
  }

  /// Получить проект по ID
  Future<Project?> getById(int id) async {
    return await (select(projects)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// Создать новый проект
  Future<int> create(String name, {String? color}) async {
    return await into(projects).insert(
      ProjectsCompanion.insert(
        name: name,
        color: Value(color),
      ),
    );
  }

  /// Обновить проект по ID
  Future<int> updateProject(
    int id, {
    String? name,
    String? color,
  }) async {
    return await (update(projects)..where((t) => t.id.equals(id))).write(
      ProjectsCompanion(
        name: name != null ? Value(name) : const Value.absent(),
        color: color != null ? Value(color) : const Value.absent(),
      ),
    );
  }

  /// Архивировать проект
  Future<int> archive(int id) async {
    return await (update(projects)..where((t) => t.id.equals(id))).write(
      const ProjectsCompanion(isArchived: Value(true)),
    );
  }

  /// Восстановить из архива
  Future<int> unarchive(int id) async {
    return await (update(projects)..where((t) => t.id.equals(id))).write(
      const ProjectsCompanion(isArchived: Value(false)),
    );
  }

  /// Удалить проект по ID
  Future<int> deleteById(int id) async {
    return await (delete(projects)..where((t) => t.id.equals(id))).go();
  }

  /// Reactive stream всех активных проектов
  Stream<List<Project>> watchActive() {
    return (select(projects)..where((t) => t.isArchived.equals(false))).watch();
  }
}