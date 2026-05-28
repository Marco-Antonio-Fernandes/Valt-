import 'package:shared_preferences/shared_preferences.dart';

/// Persistência dos tutoriais de onboarding (ShowcaseView).
class VaultTutorialStore {
  static const String _completedKey = 'vault_tutorial_completed_v1';
  static const String _pendingKey = 'vault_tutorial_pending_v1';
  static const String _readerCompletedKey = 'vault_reader_tutorial_completed_v1';

  Future<bool> isCompleted() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_completedKey) ?? false;
  }

  Future<void> markCompleted() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_completedKey, true);
    await p.remove(_pendingKey);
  }

  Future<bool> isPending() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_pendingKey) ?? false;
  }

  Future<void> markPending() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_pendingKey, true);
  }

  Future<void> clearPending() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_pendingKey);
  }

  Future<bool> isReaderTutorialCompleted() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_readerCompletedKey) ?? false;
  }

  Future<void> markReaderTutorialCompleted() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_readerCompletedKey, true);
  }
}
