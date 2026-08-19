import 'dart:math';

import 'package:drift/drift.dart';

import '../database.dart';

// Часть для кодогенерации Drift.
part 'ai_lessons_dao.g.dart';

/// DAO для работы с выводами AI (слой обучения агента).
@DriftAccessor(tables: [AiLessons])
class AiLessonsDao extends DatabaseAccessor<AppDatabase>
    with _$AiLessonsDaoMixin {
  AiLessonsDao(super.db);

  /// Получить все выводы.
  Future<List<AiLesson>> getAll() {
    return (select(aiLessons)
          ..orderBy([(t) => OrderingTerm.desc(t.confidence)]))
        .get();
  }

  /// Получить выводы по категории.
  Future<List<AiLesson>> getByCategory(LessonCategory category) {
    return (select(aiLessons)
          ..where((t) => t.category.equals(category.name))
          ..orderBy([(t) => OrderingTerm.desc(t.confidence)]))
        .get();
  }

  /// Получить только надёжные выводы (confidence >= threshold).
  Future<List<AiLesson>> getReliable({double threshold = 0.7}) {
    return (select(aiLessons)
          ..where((t) => t.confidence.isBiggerOrEqualValue(threshold))
          ..orderBy([(t) => OrderingTerm.desc(t.confidence)]))
        .get();
  }

  /// Получить вывод по ID.
  Future<AiLesson?> getById(int id) {
    return (select(aiLessons)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Создать новый вывод.
  Future<int> create({
    required LessonCategory category,
    required String lesson,
    double? numericValue,
    double confidence = 0.5,
    int evidenceCount = 1,
  }) async {
    if (confidence < 0.0 || confidence > 1.0) {
      throw ArgumentError('confidence must be between 0.0 and 1.0');
    }
    if (evidenceCount < 1) {
      throw ArgumentError('evidenceCount must be at least 1');
    }

    return await into(aiLessons).insert(
      AiLessonsCompanion.insert(
        category: category,
        lesson: lesson,
        numericValue: Value(numericValue),
        confidence: Value(confidence),
        evidenceCount: Value(evidenceCount),
      ),
    );
  }

  /// Обновить вывод.
  Future<int> updateLesson(
    int id, {
    String? lesson,
    double? numericValue,
    double? confidence,
    int? evidenceCount,
  }) async {
    if (confidence != null && (confidence < 0.0 || confidence > 1.0)) {
      throw ArgumentError('confidence must be between 0.0 and 1.0');
    }
    if (evidenceCount != null && evidenceCount < 1) {
      throw ArgumentError('evidenceCount must be at least 1');
    }

    return await (update(aiLessons)..where((t) => t.id.equals(id))).write(
      AiLessonsCompanion(
        lesson: lesson != null ? Value(lesson) : const Value.absent(),
        numericValue:
            numericValue != null ? Value(numericValue) : const Value.absent(),
        confidence:
            confidence != null ? Value(confidence) : const Value.absent(),
        evidenceCount:
            evidenceCount != null ? Value(evidenceCount) : const Value.absent(),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Подтвердить вывод новым наблюдением.
  Future<int> reinforce(int id) async {
    final lesson = await getById(id);
    if (lesson == null) return 0;

    final newEvidenceCount = lesson.evidenceCount + 1;
    final newConfidence = min(1.0, 0.5 + log(newEvidenceCount) * 0.2);

    return await (update(aiLessons)..where((t) => t.id.equals(id))).write(
      AiLessonsCompanion(
        evidenceCount: Value(newEvidenceCount),
        confidence: Value(newConfidence),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Опустить confidence (если наблюдение противоречит выводу).
  Future<int> contradict(int id) async {
    final lesson = await getById(id);
    if (lesson == null) return 0;

    final newConfidence = max(0.1, lesson.confidence - 0.1);

    return await (update(aiLessons)..where((t) => t.id.equals(id))).write(
      AiLessonsCompanion(
        confidence: Value(newConfidence),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Удалить вывод по ID.
  Future<int> deleteById(int id) {
    return (delete(aiLessons)..where((t) => t.id.equals(id))).go();
  }

  /// Получить коэффициент для корректировки оценок времени.
  Future<double> getEstimationCoefficient() async {
    final estimates = await getByCategory(LessonCategory.estimates);
    for (final lesson in estimates) {
      if (lesson.numericValue != null && lesson.confidence >= 0.7) {
        return lesson.numericValue!;
      }
    }
    return 1.0;
  }
}
