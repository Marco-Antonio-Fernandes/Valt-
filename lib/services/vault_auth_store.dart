import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class VaultUser {
  const VaultUser({
    required this.id,
    required this.email,
    required this.displayName,
    required this.bio,
  });

  final String id;
  final String email;
  final String displayName;
  final String bio;

  factory VaultUser.fromJson(Map<String, dynamic> json) {
    return VaultUser(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      bio: json['bio'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'display_name': displayName,
        'bio': bio,
      };
}

class VaultAuthSession {
  const VaultAuthSession({required this.token, required this.user});

  final String token;
  final VaultUser user;

  Map<String, dynamic> toJson() => {'token': token, 'user': user.toJson()};

  static VaultAuthSession? fromCombinedJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final t = j['token'] as String?;
    final u = j['user'] as Map<String, dynamic>?;
    if (t == null || t.isEmpty || u == null) return null;
    return VaultAuthSession(token: t, user: VaultUser.fromJson(u));
  }
}

class VaultAuthStore {
  static const String _tokenKey = 'vault_auth_token_v1';
  static const String _userJsonKey = 'vault_auth_user_json_v1';

  Future<String?> readToken() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_tokenKey);
  }

  Future<VaultUser?> readCachedUser() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_userJsonKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return VaultUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSession(String token, VaultUser user) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_tokenKey, token);
    await p.setString(_userJsonKey, jsonEncode(user.toJson()));
  }

  Future<void> clearSession() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_tokenKey);
    await p.remove(_userJsonKey);
  }
}
