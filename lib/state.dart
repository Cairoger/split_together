import 'package:flutter/widgets.dart';

import 'data/repository.dart';
import 'domain.dart';

class AppController extends ChangeNotifier {
  AppController(this.repo);
  final SplitRepository repo;
  AppData? _data;
  Object? error;
  bool _closed = false;
  AppData get data => _data!;
  bool get ready => _data != null;
  Ledger group(String id) => data.groups.firstWhere((g) => g.id == id);

  Future<void> initialize() async {
    error = null;
    if (!_closed) notifyListeners();
    try {
      _data = await repo.load();
    } catch (e) {
      error = e;
    }
    if (!_closed) notifyListeners();
  }

  Future<T> change<T>(Future<T> Function(SplitRepository) action) async {
    final result = await action(repo);
    // A committed write must never look like a failed submission if reload fails.
    await initialize();
    return result;
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}

class AppScope extends InheritedNotifier<AppController> {
  const AppScope({
    super.key,
    required AppController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
