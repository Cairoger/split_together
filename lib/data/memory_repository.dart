import '../domain.dart';
import 'repository.dart';

class MemorySplitRepository extends LedgerRepository {
  String _name = '我';
  AppAppearance _appearance = AppAppearance.light;
  final _groups = <String, Ledger>{};

  @override
  Future<AppData> load() async => AppData(
    defaultName: _name,
    appearance: _appearance,
    groups: _groups.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
  );

  @override
  Future<void> writeName(String value) async {
    _name = value;
  }

  @override
  Future<void> setAppearance(AppAppearance value) async {
    _appearance = value;
  }

  @override
  Future<String> insertGroup(Ledger Function(String) build) async {
    final group = build(_name);
    _groups[group.id] = group;
    return group.id;
  }

  @override
  Future<void> changeGroup(String id, Ledger Function(Ledger) update) async {
    final group = _groups[id];
    if (group == null) throw const FormatException('找不到群組');
    final next = update(group);
    final expenseIds = next.expenses.map((e) => e.id).toSet();
    final paymentIds = next.repayments.map((r) => r.id).toSet();
    for (final other in _groups.values.where((g) => g.id != id)) {
      if (other.expenses.any((e) => expenseIds.contains(e.id)) ||
          other.repayments.any((r) => paymentIds.contains(r.id))) {
        throw const FormatException('這筆紀錄屬於其他群組');
      }
    }
    _groups[id] = next;
  }

  @override
  Future<void> close() async {}
}
