import 'dart:async';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../config/vault_backend_config.dart';
import '../services/vault_auth_api.dart';
import '../services/vault_auth_store.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.authApi,
    required this.authStore,
  });

  final VaultAuthApi authApi;
  final VaultAuthStore authStore;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _guestTabCtrl;

  bool _busy = false;
  String? _token;
  VaultUser? _user;

  final _loginEmailCtrl = TextEditingController();
  final _loginPwCtrl = TextEditingController();

  final _regEmailCtrl = TextEditingController();
  final _regPwCtrl = TextEditingController();
  final _regNameCtrl = TextEditingController();

  final _profNameCtrl = TextEditingController();
  final _profBioCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _guestTabCtrl = TabController(length: 2, vsync: this);
    _boot();
  }

  Future<void> _boot() async {
    final t = await widget.authStore.readToken();
    final cached = await widget.authStore.readCachedUser();
    if (!mounted) return;
    setState(() {
      _token = t;
      _user = cached;
    });
    if (t != null && t.isNotEmpty) {
      try {
        final fresh = await widget.authApi.fetchMe(t);
        if (!mounted) return;
        setState(() {
          _user = fresh;
        });
        await widget.authStore.saveSession(t, fresh);
      } catch (_) {
        /* servidor offline ou token expirado: mantém cache */
      }
    }
    _syncProfileFields();
  }

  void _syncProfileFields() {
    final u = _user;
    if (u != null) {
      _profNameCtrl.text = u.displayName;
      _profBioCtrl.text = u.bio;
    }
  }

  /// Ligação/partida de rede/timeouts — falha fora do [VaultAuthApiException].
  String _readableAuthFailure(Object error) {
    if (error is TimeoutException) {
      return 'O servidor não respondeu a tempo. Confirma ligação, VPN e URL do servidor (definido em desenvolvimento com --dart-define=VAULT_BACKEND_URL=… ).';
    }
    final raw = error.toString();
    if (raw.contains('SocketException') ||
        raw.contains('Failed host lookup') ||
        raw.contains('Connection refused') ||
        raw.contains('HandshakeException') ||
        raw.contains('ClientException') ||
        raw.contains('Network is unreachable')) {
      return 'Não foi possível ligar ao servidor (rede DNS, servidor desligado ou URL incorreta). Repara o texto “Servidor:” neste ecrã.';
    }
    return 'Erro ao contactar o servidor: $raw';
  }

  @override
  void dispose() {
    _guestTabCtrl.dispose();
    _loginEmailCtrl.dispose();
    _loginPwCtrl.dispose();
    _regEmailCtrl.dispose();
    _regPwCtrl.dispose();
    _regNameCtrl.dispose();
    _profNameCtrl.dispose();
    _profBioCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    setState(() => _busy = true);
    try {
      final s = await widget.authApi.login(
        email: _loginEmailCtrl.text,
        password: _loginPwCtrl.text,
      );
      await widget.authStore.saveSession(s.token, s.user);
      if (!mounted) return;
      setState(() {
        _token = s.token;
        _user = s.user;
        _busy = false;
      });
      _syncProfileFields();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sessão iniciada.')));
    } on VaultAuthApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_readableAuthFailure(e))));
    }
  }

  Future<void> _handleRegister() async {
    setState(() => _busy = true);
    try {
      final s = await widget.authApi.register(
        email: _regEmailCtrl.text,
        password: _regPwCtrl.text,
        displayName: _regNameCtrl.text,
      );
      await widget.authStore.saveSession(s.token, s.user);
      if (!mounted) return;
      setState(() {
        _token = s.token;
        _user = s.user;
        _busy = false;
      });
      _syncProfileFields();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Conta criada.')));
    } on VaultAuthApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_readableAuthFailure(e))));
    }
  }

  Future<void> _saveProfile() async {
    final t = _token;
    if (t == null || t.isEmpty) return;
    setState(() => _busy = true);
    try {
      final updated = await widget.authApi.updateProfile(
        token: t,
        displayName: _profNameCtrl.text,
        bio: _profBioCtrl.text,
      );
      await widget.authStore.saveSession(t, updated);
      if (!mounted) return;
      setState(() {
        _user = updated;
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Perfil atualizado.')));
    } on VaultAuthApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_readableAuthFailure(e))));
    }
  }

  Future<void> _logout() async {
    await widget.authStore.clearSession();
    if (!mounted) return;
    setState(() {
      _token = null;
      _user = null;
    });
    _profNameCtrl.clear();
    _profBioCtrl.clear();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saíste da conta.')));
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final logged = (_token ?? '').isNotEmpty && _user != null;
    final host = VaultBackendConfig.baseUrl.replaceFirst(RegExp(r'/v1$'), '');

    return Scaffold(
      backgroundColor: AppTheme.black,
      appBar: AppBar(
        backgroundColor: AppTheme.black,
        surfaceTintColor: Colors.transparent,
        title: const Text('Conta Vault'),
        bottom: logged
            ? null
            : TabBar(
                controller: _guestTabCtrl,
                tabs: const [
                  Tab(text: 'Entrar'),
                  Tab(text: 'Criar conta'),
                ],
              ),
      ),
      body: logged
          ? _loggedBody(c, host)
          : TabBarView(
              controller: _guestTabCtrl,
              children: [
                _loginForm(c, host),
                _registerForm(c, host),
              ],
            ),
    );
  }

  Widget _loginForm(ColorScheme c, String host) {
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text('Servidor: $host', style: TextStyle(color: c.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 20),
        TextField(
          controller: _loginEmailCtrl,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _loginPwCtrl,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Palavra-passe'),
        ),
        const SizedBox(height: 22),
        FilledButton(
          onPressed: _busy ? null : _handleLogin,
          child:
              _busy
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Entrar'),
        ),
      ],
    );
  }

  Widget _registerForm(ColorScheme c, String host) {
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text('Servidor: $host', style: TextStyle(color: c.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 20),
        TextField(
          controller: _regNameCtrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nome a mostrar'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _regEmailCtrl,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _regPwCtrl,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Palavra-passe (≥ 8 caracteres)'),
        ),
        const SizedBox(height: 22),
        FilledButton(
          onPressed: _busy ? null : _handleRegister,
          child:
              _busy
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Registar'),
        ),
      ],
    );
  }

  Widget _loggedBody(ColorScheme c, String host) {
    final u = _user!;
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text('Servidor\n$host', style: TextStyle(color: c.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 14),
        Text(u.email, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 22),
        TextField(
          controller: _profNameCtrl,
          decoration: const InputDecoration(labelText: 'Nome'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _profBioCtrl,
          maxLines: 5,
          decoration: const InputDecoration(
            alignLabelWithHint: true,
            labelText: 'Sobre mim / notas',
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : _saveProfile,
                child: const Text('Guardar perfil'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : _logout,
                child: const Text('Sair'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
