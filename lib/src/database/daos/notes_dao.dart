import 'package:drift/drift.dart';

import '../database.dart';

part 'notes_dao.g.dart';

/// DAO для работы с заметками и идеями
@DriftAccessor(tables: [Notes])
class NotesDao extends DatabaseAccessor<AppDatabase> with _$NotesDaoMixin {
  NotesDao(super.db);

  /// Получить все заметки из инбокса
  Future<List<Note>> getInbox() async {
    return await (select(notes)
          ..where((n) => n.status.equals(NoteStatus.inbox.name)))
        .get();
  }

  /// Получить все заметки по тегу
  Future<List<Note>> getByTag(String tag) async {
    return await (select(notes)..where((n) => n.tags.like('%$tag%'))).get();
  }

  /// Получить количество заметок в инбоксе
  Future<int> getInboxCount() async {
    final query = selectOnly(notes)
      ..where(notes.status.equals(NoteStatus.inbox.name))
      ..addColumns([notes.id.count()]);
    final result = await query.getSingle();
    return result.read(notes.id.count()) ?? 0;
  }

  /// Получить заметку по ID
  Future<Note?> getById(int id) async {
    return await (select(notes)..where((n) => n.id.equals(id)))
        .getSingleOrNull();
  }

  /// Создать новую заметку
  Future<int> create({
    required String content,
    NoteKind kind = NoteKind.note,
    NoteStatus status = NoteStatus.inbox,
    int? linkedTaskId,
    String? tags,
  }) async {
    return await into(notes).insert(
      NotesCompanion.insert(
        content: content,
        kind: Value(kind),
        status: Value(status),
        linkedTaskId: Value(linkedTaskId),
        tags: Value(tags),
      ),
    );
  }

  /// Обновить заметку по ID
  Future<int> updateNote(
    int id, {
    String? content,
    NoteKind? kind,
    NoteStatus? status,
    int? linkedTaskId,
    String? tags,
  }) async {
    return await (update(notes)..where((n) => n.id.equals(id))).write(
      NotesCompanion(
        content: content != null ? Value(content) : const Value.absent(),
        kind: kind != null ? Value(kind) : const Value.absent(),
        status: status != null ? Value(status) : const Value.absent(),
        linkedTaskId:
            linkedTaskId != null ? Value(linkedTaskId) : const Value.absent(),
        tags: tags != null ? Value(tags) : const Value.absent(),
      ),
    );
  }

  /// Связать заметку с задачей (promote to task)
  Future<int> promoteToTask(int noteId, int taskId) async {
    return await (update(notes)..where((n) => n.id.equals(noteId))).write(
      NotesCompanion(
        linkedTaskId: Value(taskId),
        status: const Value(NoteStatus.promoted),
      ),
    );
  }

  /// Архивировать заметку
  Future<int> archive(int id) async {
    return await (update(notes)..where((n) => n.id.equals(id))).write(
      const NotesCompanion(status: Value(NoteStatus.archived)),
    );
  }

  /// Вернуть заметку в инбокс
  Future<int> restoreToInbox(int id) async {
    return await (update(notes)..where((n) => n.id.equals(id))).write(
      const NotesCompanion(
        status: Value(NoteStatus.inbox),
        linkedTaskId: Value(null),
      ),
    );
  }

  /// Удалить заметку по ID
  Future<int> deleteById(int id) async {
    return await (delete(notes)..where((n) => n.id.equals(id))).go();
  }
}
