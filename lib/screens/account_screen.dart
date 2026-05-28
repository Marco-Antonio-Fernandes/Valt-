import 'dart:async';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../config/vault_backend_config.dart';
import '../models/library_item.dart';
import '../services/vault_auth_api.dart';
import '../services/vault_auth_store.dart';
import '../utils/reading_progress.dart';
import '../widgets/local_cover_image.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.authApi,
    required this.authStore,
    this.libraryItems = const [],
    this.embeddedInLibrary = false,
    this.onSessionEnded,
  });

  final VaultAuthApi authApi;
  final VaultAuthStore authStore;

  /// Biblioteca local — alimenta o registo de leitura no perfil.
  final List<LibraryItem> libraryItems;

  /// Na biblioteca o utilizador já passou pelo gate de login.
  final bool embeddedInLibrary;

  /// Chamado após sair ou apagar conta (volta ao ecrã de login).
  final VoidCallback? onSessionEnded;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _guestTabCtrl;

  bool _busy = false;
  String? _token;
  VaultUser? _user;

  final _loginApelidoCtrl = TextEditingController();
  final _loginPwCtrl = TextEditingController();

  final _regApelidoCtrl = TextEditingController();
  final _regPwCtrl = TextEditingController();

  final _profNameCtrl = TextEditingController();
  final _deletePwCtrl = TextEditingController();

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
    _loginApelidoCtrl.dispose();
    _loginPwCtrl.dispose();
    _regApelidoCtrl.dispose();
    _regPwCtrl.dispose();
    _profNameCtrl.dispose();
    _deletePwCtrl.dispose();
    super.dispose();
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
        apelido: _regApelidoCtrl.text,
        password: _regPwCtrl.text,
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
        bio: _user?.bio ?? '',
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
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saíste da conta.')));
    widget.onSessionEnded?.call();
  }

  Future<void> _deleteAccountFlow() async {
    final t = _token;
    if (t == null || !mounted) return;
    _deletePwCtrl.clear();

    final pwd = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.black,
        title: const Text('Apagar conta?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'A conta será eliminada no servidor (base de dados). '
                'Os comics ou PDFs guardados só neste dispositivo não são apagados.',
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _deletePwCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Palavra-passe para confirmar',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () {
              final p = _deletePwCtrl.text;
              if (p.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content:
                        Text('Introduz a palavra-passe para confirmar a eliminação.'),
                  ),
                );
                return;
              }
              Navigator.pop(ctx, p);
            },
            child: const Text('Apagar conta'),
          ),
        ],
      ),
    );

    if (pwd == null || pwd.isEmpty || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.authApi.deleteAccount(
        token: t,
        confirmationPassword: pwd,
      );
      await widget.authStore.clearSession();
      if (!mounted) return;
      setState(() {
        _token = null;
        _user = null;
        _busy = false;
      });
      _profNameCtrl.clear();
      _deletePwCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Conta eliminada no servidor.'),
        ),
      );
      if (widget.embeddedInLibrary) {
        widget.onSessionEnded?.call();
      } else {
        Navigator.of(context).pop();
      }
    } on VaultAuthApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
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
    final logged = (_token ?? '').isNotEmpty && _user != null;
    final host = VaultBackendConfig.baseUrl.replaceFirst(RegExp(r'/v1$'), '');
    final showGuest = !logged && !widget.embeddedInLibrary;

    return Scaffold(
      backgroundColor: AppTheme.black,
      appBar: AppBar(
        backgroundColor: AppTheme.black,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.embeddedInLibrary ? 'Perfil' : 'Conta Vault'),
        bottom: showGuest
            ? TabBar(
                controller: _guestTabCtrl,
                tabs: const [
                  Tab(text: 'Entrar'),
                  Tab(text: 'Criar conta'),
                ],
              )
            : null,
      ),
      body: logged
          ? _loggedBody(c, host)
          : showGuest
              ? TabBarView(
                  controller: _guestTabCtrl,
                  children: [
                    _loginForm(c, host),
                    _registerForm(c, host),
                  ],
                )
              : Center(
                  child: CircularProgressIndicator(
                    color: c.primary,
                    strokeWidth: 2.5,
                  ),
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
          controller: _loginApelidoCtrl,
          decoration: const InputDecoration(labelText: 'Apelido'),
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
          controller: _regApelidoCtrl,
          decoration: const InputDecoration(
            labelText: 'Apelido',
            helperText: 'Mínimo 3 caracteres; único na conta',
          ),
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
    final completed = readingLogCompleted(widget.libraryItems);
    final inProgress = readingLogInProgress(widget.libraryItems);
    final totalRead = completed.length + inProgress.length;

    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text('Servidor\n$host', style: TextStyle(color: c.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: 14),
        Text('@${u.apelido}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 22),
        TextField(
          controller: _profNameCtrl,
          decoration: const InputDecoration(labelText: 'Nome'),
        ),
        const SizedBox(height: 24),
        _readingLogHeader(c, completed.length, inProgress.length, totalRead),
        const SizedBox(height: 16),
        if (totalRead == 0)
          _readingLogEmpty(c)
        else ...[
          if (inProgress.isNotEmpty) ...[
            _readingLogSectionTitle('A ler agora', inProgress.length, c),
            const SizedBox(height: 10),
            for (final item in inProgress) ...[
              _ReadingLogTile(item: item, completed: false, colorScheme: c),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 8),
          ],
          if (completed.isNotEmpty) ...[
            _readingLogSectionTitle('Concluídos', completed.length, c),
            const SizedBox(height: 10),
            for (final item in completed) ...[
              _ReadingLogTile(item: item, completed: true, colorScheme: c),
              const SizedBox(height: 10),
            ],
          ],
        ],
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
        const SizedBox(height: 28),
        Divider(color: c.outlineVariant.withValues(alpha: 0.6)),
        const SizedBox(height: 12),
        Text(
          'Eliminar conta',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: c.error,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          'Pedido irreversível no servidor onde tens sessão iniciada.',
          style: TextStyle(color: c.onSurfaceVariant, fontSize: 12),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: c.error,
              side: BorderSide(color: c.error.withValues(alpha: 0.85)),
            ),
            onPressed: _busy ? null : _deleteAccountFlow,
            child: const Text('Apagar conta no servidor'),
          ),
        ),
      ],
    );
  }

  Widget _readingLogHeader(
    ColorScheme c,
    int completedCount,
    int inProgressCount,
    int totalRead,
  ) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: c.surfaceContainerHigh,
        border: Border.all(color: c.outline.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Registo de leitura',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.25,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              totalRead == 0
                  ? 'Ainda não há livros lidos neste dispositivo.'
                  : '$completedCount concluído${completedCount == 1 ? '' : 's'}'
                      '${inProgressCount > 0 ? ' · $inProgressCount a ler' : ''}'
                      ' · $totalRead no total',
              style: TextStyle(color: c.onSurfaceVariant, height: 1.4, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readingLogEmpty(ColorScheme c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        'Importa um livro na Biblioteca e abre-o — o progresso aparece aqui.',
        style: TextStyle(color: c.onSurfaceVariant, fontSize: 13, height: 1.45),
      ),
    );
  }

  Widget _readingLogSectionTitle(String title, int count, ColorScheme c) {
    return Row(
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: AppTheme.ink,
              ),
        ),
        const SizedBox(width: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            color: c.primaryContainer.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              '$count',
              style: TextStyle(
                color: c.onPrimaryContainer,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReadingLogTile extends StatelessWidget {
  const _ReadingLogTile({
    required this.item,
    required this.completed,
    required this.colorScheme,
  });

  final LibraryItem item;
  final bool completed;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final c = colorScheme;
    final fraction = readingProgressFraction(item);
    final percent = readingProgressPercent(item);
    final label = readingProgressLabel(item);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: c.surfaceContainerHigh,
        border: Border.all(
          color: completed
              ? c.tertiary.withValues(alpha: 0.35)
              : c.outline.withValues(alpha: 0.28),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 46,
                height: 62,
                child: localCoverImage(
                  path: item.coverPath,
                  fit: BoxFit.cover,
                  fallback: ColoredBox(
                    color: c.surfaceContainerHighest,
                    child: Icon(
                      Icons.menu_book_rounded,
                      color: c.primary.withValues(alpha: 0.9),
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: completed ? c.tertiary : c.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.35,
                      fontWeight: completed ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (!completed && fraction != null) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: fraction,
                        minHeight: 5,
                        backgroundColor: c.outline.withValues(alpha: 0.35),
                        color: c.primary,
                      ),
                    ),
                    if (percent != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '$percent%',
                        style: TextStyle(
                          color: c.onSurfaceVariant,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ] else if (completed) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.check_circle_rounded, size: 14, color: c.tertiary),
                        const SizedBox(width: 4),
                        Text(
                          'Lido até ao fim',
                          style: TextStyle(
                            color: c.tertiary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
