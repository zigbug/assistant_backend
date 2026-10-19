# Multi-stage сборка: AOT-компиляция в SDK-образе + минимальный рантайм.
#
# Раньше контейнер запускал `dart run bin/server.dart` (JIT) — рабочий обход
# старых проблем `dart compile exe` с build hooks пакета sqlite3, но он таскал
# весь Dart SDK и компилятор: ~250 МБ RSS на процесс против ~30 МБ у готового
# бинарника. В Dart 3.13 появился `dart build cli`, который умеет и build hooks,
# и AOT — им и собираем.
#
# Бандл: bin/server (AOT) + lib/libsqlite3.so. Бинарник линкуется к
# `libsqlite3.so` по имени и ищет её через RUNPATH=$ORIGIN/../lib, поэтому
# библиотеку достаточно положить рядом — LD_LIBRARY_PATH не нужен.

# ---------- build ----------
FROM dart:stable AS build

WORKDIR /app

# Кэш пакетов внутри /app, чтобы был доступен на всех этапах без root.
ENV PUB_CACHE=/app/.pub-cache

# 1. Манифесты — кэшируемый слой с зависимостями.
COPY pubspec.* ./
RUN dart pub get

# 2. Исходники.
COPY . .

# 3. Генерируем Drift/json-код (*.g.dart). В git эти файлы не хранятся
#    (.gitignore), поэтому без шага сборка из чистого чекаута падает.
RUN dart run build_runner build --delete-conflicting-outputs

# 4. AOT-бандл: `dart build cli` прогоняет build hooks (готовит libsqlite3.so)
#    и компилирует нативный бинарник. `-o` уже создаёт подкаталог `bundle/`,
#    поэтому результат: /app/bundle/bundle/bin/server и …/lib/libsqlite3.so.
RUN dart build cli -o /app/bundle

# ---------- runtime ----------
# distroless: без shell и пакетного менеджера — только glibc/openssl/ca-certificates.
# Меньше образ и меньше поверхность атаки. uid nonroot = 65532.
FROM gcr.io/distroless/cc-debian12:nonroot

# Локальная зона планировщика. В distroless нет tzdata, поэтому кладём файл
# зоны в стандартный TZDIR. Без него планировщик уйдёт в UTC, и «09:00»
# встанет в 12:00 по Москве, а дата-без-времени сдвинется на сутки.
ENV TZ=Europe/Moscow
COPY --from=build /usr/share/zoneinfo/Europe/Moscow /usr/share/zoneinfo/Europe/Moscow

WORKDIR /app

# Бандл отдаём nonroot-владельцу сразу через --chown. Бинарник кладём в
# /app/bin/server, а sqlite3.so — в /app/lib, как ожидает RUNPATH=$ORIGIN/../lib.
COPY --from=build --chown=65532:65532 /app/bundle/bundle/bin/server /app/bin/server
COPY --from=build --chown=65532:65532 /app/bundle/bundle/lib/libsqlite3.so /app/lib/libsqlite3.so

# Каталог под SQLite-том. Пустой named volume при первом монтировании
# наследует владельца каталога из образа — значит каталог должен существовать
# в образе и принадлежать nonroot. distroless не умеет RUN, поэтому создаём
# каталог через COPY: копируем пустышку в нужный путь.
COPY --from=build --chown=65532:65532 /app/bundle/bundle/lib/libsqlite3.so /app/data/.keep

ENV HOST=0.0.0.0
ENV PORT=8081
ENV DATA_DIR=/app/data

EXPOSE 8081

# Запуск без shell: distroless не содержит /bin/sh.
ENTRYPOINT ["/app/bin/server"]
