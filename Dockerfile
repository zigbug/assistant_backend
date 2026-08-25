# --- Stage 1: Build ---
FROM dart:stable AS build
WORKDIR /app

# Сначала только манифест зависимостей для кэширования слоя
COPY pubspec.* ./
RUN dart pub get

# Копируем весь код и компилируем в нативный AOT-бинарник
COPY . .
RUN dart compile exe bin/server.dart -o /out/server

# --- Stage 2: Runtime ---
FROM debian:bookworm-slim

# Устанавливаем только необходимое для работы (ca-certificates для HTTPS, libsqlite3-0 для fallback)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

# Безопасность: запускаем от non-root пользователя
RUN useradd -r -u 10001 appuser

COPY --from=build /out/server /usr/local/bin/server
USER appuser
EXPOSE 8081

# Запускаем скомпилированный бинарник
ENTRYPOINT ["server"]