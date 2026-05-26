/// Configuração de URLs do backend Vault.
///
/// O FastAPI monta routers com prefixos diferentes:
/// - **Auth**: `/auth` (sem `/v1`)
/// - **Piper, MangaDex, etc.**: `/v1/...`
///
/// ### Produção
/// `https://valt.rotatix.com.br`
///
/// ### Desenvolvimento local
/// `flutter run --dart-define=VAULT_BACKEND_URL=http://127.0.0.1:8080`
///
/// (Em **Android Emulator**, troca por `http://10.0.2.2:8080`.)
class VaultBackendConfig {
  VaultBackendConfig._();

  /// Raiz do servidor (sem `/v1`). Override com `--dart-define`.
  static const String _rawBaseUrl = String.fromEnvironment(
    'VAULT_BACKEND_URL',
    defaultValue: 'https://valt.rotatix.com.br',
  );

  static String get _root {
    var url = _rawBaseUrl;
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (url.endsWith('/v1')) url = url.substring(0, url.length - 3);
    return url;
  }

  /// URL base para routers versionados (`/v1/piper/…`, `/v1/mangadex/…`).
  static String get baseUrl => '$_root/v1';

  /// URI para endpoints **versionados** (`/v1/…`).
  static Uri uri(String path, [Map<String, String>? query]) {
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$baseUrl$p').replace(queryParameters: query);
  }

  /// URI para endpoints **sem** prefixo `/v1` (ex.: `/auth/…`).
  static Uri rootUri(String path, [Map<String, String>? query]) {
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$_root$p').replace(queryParameters: query);
  }
}
