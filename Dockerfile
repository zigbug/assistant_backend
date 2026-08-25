# Используем полноценный Dart SDK.
# Это надежнее, чем AOT-компиляция, так как обходит проблемы
# с build hooks пакета sqlite3 в Docker-среде.
FROM dart:stable

WORKDIR /app

# Кэш пакетов держим внутри /app: иначе dart run ищет их в /root/.pub-cache,
# недоступном непривилегированному пользователю (permission denied).
ENV PUB_CACHE=/app/.pub-cache

# Непривилегированный пользователь для запуска сервера
RUN groupadd --system app \
    && useradd --system --gid app --home-dir /app app

# 1. Копируем манифесты и получаем зависимости (этот слой будет закэширован)
COPY pubspec.* ./
RUN dart pub get

# 2. Копируем исходный код
COPY . .

# 3. Генерируем Drift/json-код (*.g.dart).
# В git эти файлы не хранятся (.gitignore), поэтому без этого шага
# сборка из чистого чекаута падает с ошибками компиляции.
RUN dart run build_runner build --delete-conflicting-outputs

# Отдаём владение пользователю app.
# /app/data создаём заранее: пустой named volume при первом монтировании
# наследует владельца каталога из образа.
# Кэш build_runner в образе не нужен — удаляем для компактности.
RUN mkdir -p /app/data \
    && rm -rf .dart_tool/build \
    && chown -R app:app /app

USER app

EXPOSE 8081

# 3. Запускаем напрямую через dart run
# (Старт занимает ~1-2 сек, что отлично для бэкенда)
ENTRYPOINT ["dart", "run", "bin/server.dart"]
