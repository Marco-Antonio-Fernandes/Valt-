import 'dart:async';

import 'package:flutter/material.dart';

import '../services/vault_auth_api.dart';
import '../services/vault_auth_store.dart';
import '../services/vault_tutorial_store.dart';
import 'auth_gate_screen.dart';
import 'library_screen.dart';
import 'startup_loading_screen.dart';

/// Após o arranque do PDF: exige sessão; depois biblioteca (+ tutorial se novo registo).
class VaultSessionGate extends StatefulWidget {
  const VaultSessionGate({super.key});

  @override
  State<VaultSessionGate> createState() => _VaultSessionGateState();
}

class _VaultSessionGateState extends State<VaultSessionGate> {
  final _authApi = VaultAuthApi();
  final _authStore = VaultAuthStore();
  final _tutorialStore = VaultTutorialStore();

  var _checking = true;
  var _authenticated = false;
  var _runTutorial = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
    _authApi.close();
    super.dispose();
  }

  Future<void> _boot() async {
    final token = await _authStore.readToken();
    final pendingTutorial = await _tutorialStore.isPending();
    if (!mounted) return;
    if (token != null && token.isNotEmpty) {
      setState(() {
        _authenticated = true;
        _runTutorial = pendingTutorial;
        _checking = false;
      });
      return;
    }
    setState(() {
      _authenticated = false;
      _runTutorial = false;
      _checking = false;
    });
  }

  Future<void> _onAuthenticated({required bool isNewAccount}) async {
    if (isNewAccount) {
      await _tutorialStore.markPending();
    }
    if (!mounted) return;
    setState(() {
      _authenticated = true;
      _runTutorial = isNewAccount;
    });
  }

  void _onSessionEnded() {
    setState(() {
      _authenticated = false;
      _runTutorial = false;
    });
  }

  Future<void> _onTutorialFinished() async {
    await _tutorialStore.markCompleted();
    if (!mounted) return;
    setState(() => _runTutorial = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const StartupLoadingScreen(statusMessage: 'A verificar sessão…');
    }

    if (!_authenticated) {
      return AuthGateScreen(
        authApi: _authApi,
        authStore: _authStore,
        onAuthenticated: _onAuthenticated,
      );
    }

    return LibraryScreen(
      authApi: _authApi,
      authStore: _authStore,
      runTutorialOnStart: _runTutorial,
      onTutorialFinished: _onTutorialFinished,
      onSessionEnded: _onSessionEnded,
    );
  }
}
