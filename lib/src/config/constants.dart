/// Конфигурационные константы приложения.
///
/// TODO: В будущем заменить хардкод на чтение из переменных окружения (.env)
/// с помощью пакета `dotenv` или `envied`.
class AppConstants {
  /// Ключ API для аутентификации запросов к бэкенду.
  /// Используется для простой проверки подлинности клиентов (Flutter, MCP).
  static const String apiKey = 'your-super-secret-api-key-123';

  /// Версия API, используемая в маршрутах (например, /api/v1/...).
  static const String apiVersion = 'v1';

  /// Порт, на котором будет запущен HTTP-сервер.
  static const int serverPort = 8081;
}
