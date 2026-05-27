import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/vault_backend_config.dart';
import 'vault_auth_store.dart';

const Duration _kAuthHttpTimeout = Duration(seconds: 25);

Future<http.Response> _withTimeout(Future<http.Response> inner) =>
    inner.timeout(_kAuthHttpTimeout, onTimeout: () {
      throw TimeoutException('Servidor não respondeu a tempo (${_kAuthHttpTimeout.inSeconds}s)');
    });

class VaultAuthApiException implements Exception {
  VaultAuthApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => '$statusCode — $message';
}

class VaultAuthApi {
  VaultAuthApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static String _errorBody(String body, int status) {
    if (body.isEmpty) return 'Erro HTTP $status';
    try {
      final j = jsonDecode(body);
      if (j is Map && j['detail'] != null) {
        final d = j['detail'];
        if (d is String) return d;
        if (d is List && d.isNotEmpty && d.first is Map) {
          return (d.first as Map)['msg']?.toString() ?? body;
        }
      }
      return body;
    } catch (_) {
      return body;
    }
  }

  Future<VaultAuthSession> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    final uri = VaultBackendConfig.rootUri('/auth/register');
    final res = await _withTimeout(
      _client.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email.trim(),
          'password': password,
          'display_name': displayName.trim(),
        }),
      ),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw VaultAuthApiException(res.statusCode, _errorBody(res.body, res.statusCode));
    }
    return _decodeSession(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<VaultAuthSession> login({
    required String email,
    required String password,
  }) async {
    final uri = VaultBackendConfig.rootUri('/auth/login');
    final res = await _withTimeout(
      _client.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email.trim(), 'password': password}),
      ),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw VaultAuthApiException(res.statusCode, _errorBody(res.body, res.statusCode));
    }
    return _decodeSession(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<VaultUser> fetchMe(String token) async {
    final uri = VaultBackendConfig.rootUri('/auth/me');
    final res = await _withTimeout(
      _client.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      ),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw VaultAuthApiException(res.statusCode, _errorBody(res.body, res.statusCode));
    }
    return VaultUser.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Remove a conta do utilizador actual no servidor (registo na base de dados).
  ///
  /// Contrato esperado no API: **`DELETE /auth/me`** com `Authorization: Bearer <token>`.
  /// Corpo JSON opcional `{"password":"<palavra-passe>"}` se o backend validar a palavra-passe antes de apagar.
  Future<void> deleteAccount({
    required String token,
    String? confirmationPassword,
  }) async {
    final uri = VaultBackendConfig.rootUri('/auth/me');
    final hasPw =
        confirmationPassword != null &&
        confirmationPassword.isNotEmpty;
    final res = await _withTimeout(
      _client.delete(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          if (hasPw) 'Content-Type': 'application/json',
        },
        body: hasPw
            ? jsonEncode({'password': confirmationPassword})
            : null,
      ),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw VaultAuthApiException(
        res.statusCode,
        _errorBody(res.body, res.statusCode),
      );
    }
  }

  Future<VaultUser> updateProfile({
    required String token,
    required String displayName,
    required String bio,
  }) async {
    final uri = VaultBackendConfig.rootUri('/auth/me');
    final body = jsonEncode({'display_name': displayName.trim(), 'bio': bio.trim()});
    final res = await _withTimeout(
      _client.patch(
        uri,
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: body,
      ),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw VaultAuthApiException(res.statusCode, _errorBody(res.body, res.statusCode));
    }
    return VaultUser.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  VaultAuthSession _decodeSession(Map<String, dynamic> json) {
    final token = json['access_token'] as String?;
    final userMap = json['user'] as Map<String, dynamic>?;
    if (token == null || userMap == null) {
      throw VaultAuthApiException(500, 'Resposta inválida do servidor');
    }
    return VaultAuthSession(token: token, user: VaultUser.fromJson(userMap));
  }

  void close() => _client.close();
}
