import 'dart:async';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../config/vault_backend_config.dart';
import '../services/vault_auth_api.dart';
import '../services/vault_auth_store.dart';

/// Ecrã inicial obrigatório: entrar ou criar conta antes de usar a app.
class AuthGateScreen extends StatefulWidget {
  const AuthGateScreen({
    super.key,
    required this.authApi,
    required this.authStore,
    required this.onAuthenticated,
  });

  final VaultAuthApi authApi;
  final VaultAuthStore authStore;

  /// [isNewAccount] true quando o utilizador acabou de se registar.
  final void Function({required bool isNewAccount}) onAuthenticated;

  @override
  State<AuthGateScreen> createState() => _AuthGateScreenState();
}

class _AuthGateScreenState extends State<AuthGateScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  bool _busy = false;

  final _loginApelidoCtrl = TextEditingController();
  final _loginPwCtrl = TextEditingController();

  final _regApelidoCtrl = TextEditingController();
  final _regPwCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _loginApelidoCtrl.dispose();
    _loginPwCtrl.dispose();
    _regApelidoCtrl.dispose();
    _regPwCtrl.dispose();
    super.dispose();
  }

  String _readableAuthFailure(Object error) {
    if (error is TimeoutException) {
      return 'O servidor não respondeu a tempo. Verifica a ligação e a URL do servidor.';
    }
    final raw = error.toString();
    if (raw.contains('SocketException') ||
        raw.contains('Failed host lookup') ||
        raw.contains('Connection refused') ||
        raw.contains('HandshakeException') ||
        raw.contains('ClientException') ||
        raw.contains('Network is unreachable')) {
      return 'Não foi possível ligar ao servidor. Confirma a rede e o endereço do servidor.';
    }
    return 'Erro ao contactar o servidor: $raw';
  }

  Future<void> _handleLogin() async {
    setState(() => _busy = true);
    try {
      final s = await widget.authApi.login(
        apelido: _loginApelidoCtrl.text,
        password: _loginPwCtrl.text,
      );
      await widget.authStore.saveSession(s.token, s.user);
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onAuthenticated(isNewAccount: false);
    } on VaultAuthApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_readableAuthFailure(e))),
      );
    }
  }

  Future<void> _handleRegister() async {
    setState(() => _busy = true);
    try {
      final s = await widget.authApi.register(
        apelido: _regApelidoCtrl.text,
        password: _regPwCtrl.text,
      );
      await widget.authStore.saveSession(s.token, s.user);
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onAuthenticated(isNewAccount: true);
    } on VaultAuthApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_readableAuthFailure(e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final host = VaultBackendConfig.baseUrl.replaceFirst(RegExp(r'/v1$'), '');
    final topPad = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: AppTheme.black,
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(28, topPad + 28, 28, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          c.primary.withValues(alpha: 0.35),
                          c.primary.withValues(alpha: 0.06),
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Icon(
                        Icons.auto_stories_rounded,
                        size: 44,
                        color: c.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Vault',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.6,
                          color: AppTheme.ink,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Inicia sessão para aceder à tua biblioteca de PDFs e banda desenhada.',
                    style: TextStyle(color: AppTheme.muted, height: 1.45, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Servidor: $host',
                    style: TextStyle(color: c.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            TabBar(
              controller: _tabCtrl,
              indicatorColor: c.primary,
              labelColor: AppTheme.ink,
              unselectedLabelColor: AppTheme.muted,
              tabs: const [
                Tab(text: 'Entrar'),
                Tab(text: 'Criar conta'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  _authForm(
                    c,
                    apelidoCtrl: _loginApelidoCtrl,
                    passwordCtrl: _loginPwCtrl,
                    submitLabel: 'Entrar',
                    onSubmit: _handleLogin,
                  ),
                  _authForm(
                    c,
                    apelidoCtrl: _regApelidoCtrl,
                    passwordCtrl: _regPwCtrl,
                    submitLabel: 'Registar',
                    onSubmit: _handleRegister,
                    isRegister: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _authForm(
    ColorScheme c, {
    required TextEditingController apelidoCtrl,
    required TextEditingController passwordCtrl,
    required String submitLabel,
    required Future<void> Function() onSubmit,
    bool isRegister = false,
  }) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
      children: [
        TextField(
          controller: apelidoCtrl,
          textCapitalization: TextCapitalization.none,
          autofillHints: const [AutofillHints.username],
          decoration: InputDecoration(
            labelText: 'Apelido',
            helperText: isRegister ? 'Mínimo 3 caracteres; único na conta' : null,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: passwordCtrl,
          obscureText: true,
          autofillHints: isRegister ? null : const [AutofillHints.password],
          decoration: InputDecoration(
            labelText: isRegister
                ? 'Palavra-passe (≥ 8 caracteres)'
                : 'Palavra-passe',
          ),
        ),
        if (isRegister) ...[
          const SizedBox(height: 16),
          Text(
            'Depois de criares a conta, um tutorial guiado mostra como importar, ler, ouvir e usar notas.',
            style: TextStyle(color: c.onSurfaceVariant, fontSize: 13, height: 1.4),
          ),
        ],
        const SizedBox(height: 28),
        FilledButton(
          onPressed: _busy ? null : onSubmit,
          child: _busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(submitLabel),
        ),
      ],
    );
  }
}
