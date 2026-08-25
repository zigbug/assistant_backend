# Используем полноценный Dart SDK. 
# Это надежнее, чем AOT-компиляция, так как обходит проблемы 
# с build hooks пакета sqlite3 в Docker-среде.
FROM dart:stable

WORKDIR /app

# 1. Копируем манифесты и получаем зависимости (этот слой будет закэширован)
COPY pubspec.* ./
RUN dart pub get

# 2. Копируем весь исходный код
COPY . .

# 3. Создаем пользователя для безопасности и передаем ему права
RUN useradd -r -u 10001 appuser && \
    chown -R appuser:appuser /app

USER appuser
EXPOSE 8081

# 4. Запускаем напрямую через dart run
# (Старт занимает ~1-2 сек, что отлично для бэкенда)
ENTRYPOINT ["dart", "run", "bin/server.dart"]