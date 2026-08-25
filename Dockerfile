# --- Stage 1: Build ---
FROM dart:stable AS build
WORKDIR /app

COPY pubspec.* ./
RUN dart pub get

COPY . .

# ⭐ ВАЖНО: SQLITE3_SKIP_DOWNLOAD=1 предотвращает ошибку build hooks
RUN SQLITE3_SKIP_DOWNLOAD=1 dart compile exe bin/server.dart -o /out/server

# --- Stage 2: Runtime ---
FROM debian:bookworm-sFC
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -u 10001 appuser

COPY --from=build /out/server /usr/local/bin/server
USER appuser
EXPOSE 8081

ENTRYPOINT ["server"]