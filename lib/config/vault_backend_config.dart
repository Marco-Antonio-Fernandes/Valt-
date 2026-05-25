/// Base URL do servidor Vault (catálogo + contas).
///
/// Desenvolvimento Android emulador típico:
/// `flutter run --dart-define=VAULT_BACKEND_URL=http://10.0.2.2:8765`
/// Windows/desktop: `http://127.0.0.1:8765`
class VaultBackendConfig {
  VaultBackendConfig._();

  static const String baseUrl = String.fromEnvironment(
    'VAULT_BACKEND_URL',
    defaultValue: 'http://127.0.0.1:8765',
  );

  static Uri uri(String path, [Map<String, String>? query]) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$p').replace(queryParameters: query);
  }
}
