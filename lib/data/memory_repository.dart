import '../domain.dart';
import 'ledger_backup.dart';
import 'repository.dart';

class MemorySplitRepository extends LedgerRepository {
  String _name = '我';
  AppAppearance _appearance = AppAppearance.light;
  final _groups = <String, Ledger>{};
  final _friends = <String, NewFriend>{};
  final _archivedFriends = <String>{};
  final _quickMeals = <String, QuickMeal>{};
  BankAppChoice? _bankApp;

  @override
  Future<AppData> load() async => AppData(
    defaultName: _name,
    appearance: _appearance,
    bankApp: _bankApp,
    quickMeals: _quickMeals.values.toList()
      ..sort((a, b) {
        final byDate = b.createdAt.compareTo(a.createdAt);
        return byDate != 0 ? byDate : b.id.compareTo(a.id);
      }),
    friends: [
      for (final f in _friends.values)
        SavedFriend(
          id: f.id,
          name: f.name,
          isArchived: _archivedFriends.contains(f.id),
          bankCode: f.account?.code,
          lastFour: f.account?.number.substring(f.account!.number.length - 4),
        ),
    ],
    groups: _groups.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
  );

  @override
  Future<LedgerBackup> createBackup(DateTime createdAt) async =>
      LedgerBackup.fromData(await load(), createdAt);

  bool get _isEmpty =>
      _friends.isEmpty && _groups.isEmpty && _quickMeals.isEmpty;

  @override
  Future<bool> isLedgerEmpty() async => _isEmpty;

  @override
  Future<void> restoreBackup(LedgerBackup backup) async {
    // 在同一個同步區段檢查並寫入，不讓其他操作插入這兩步之間。
    if (!_isEmpty) throw const FormatException(nonEmptyLedgerMessage);
    final data = backup.data;
    for (final friend in data.friends) {
      _friends[friend.id] = (id: friend.id, name: friend.name, account: null);
      if (friend.isArchived) _archivedFriends.add(friend.id);
    }
    for (final group in data.groups) {
      _groups[group.id] = group;
    }
    for (final meal in data.quickMeals) {
      _quickMeals[meal.id] = meal;
    }
  }

  @override
  Future<String> createFriend(String name) async {
    final friend = newSavedFriend(name);
    _friends[friend.id] = friend;
    return friend.id;
  }

  NewFriend _activeFriend(String id) {
    if (_archivedFriends.contains(id)) throw const FormatException('找不到常用朋友');
    return _friend(id);
  }

  @override
  Future<void> renameFriend(String id, String name) async {
    final cleanName = validateFriendName(name);
    final friend = _activeFriend(id);
    _friends[id] = (id: id, name: cleanName, account: friend.account);
  }

  @override
  Future<void> archiveFriend(String id) async {
    _activeFriend(id);
    _archivedFriends.add(id);
  }

  @override
  Future<void> saveQuickMeal(QuickMeal meal) async {
    final saved = _quickMeals[meal.id];
    if (saved != null) {
      saved.verifyRetry(meal);
      return;
    }
    for (final id in meal.people.keys.where(meal.needsSavedFriend)) {
      _activeFriend(id);
    }
    _quickMeals[meal.id] = meal;
  }

  @override
  Future<void> writeName(String value) async {
    _name = value;
  }

  @override
  Future<void> setAppearance(AppAppearance value) async {
    _appearance = value;
  }

  @override
  Future<String> insertGroup(
    Ledger Function(String) build, {
    List<NewFriend> newFriends = const [],
  }) async {
    final group = build(_name);
    _commitFriends(group, newFriends);
    _groups[group.id] = group;
    return group.id;
  }

  @override
  Future<void> changeGroup(
    String id,
    Ledger Function(Ledger) update, {
    List<NewFriend> newFriends = const [],
  }) async {
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
    _commitFriends(next, newFriends, previous: group);
    _groups[id] = next;
  }

  void _commitFriends(
    Ledger group,
    List<NewFriend> additions, {
    Ledger? previous,
  }) {
    final existingLinks = {
      for (final m in previous?.members ?? const <Member>[]) m.id: m.friendId,
    };
    final newIds = additions.map((f) => f.id).toSet();
    for (final m in group.members) {
      final id = m.friendId;
      if (id != null && existingLinks[m.id] != id && !newIds.contains(id)) {
        _activeFriend(id);
      }
    }
    for (final friend in additions) {
      _friends[friend.id] = friend;
    }
  }

  NewFriend _friend(String id) =>
      _friends[id] ?? (throw const FormatException('找不到常用朋友'));

  @override
  Future<void> setBankApp(BankAppChoice? choice) async {
    _bankApp = choice;
  }

  @override
  Future<String?> readFriendAccount(String friendId) async =>
      _friend(friendId).account?.number;

  @override
  Future<void> setFriendAccount(
    String friendId,
    String? bankCode,
    String? accountNumber,
  ) async {
    final old = _friend(friendId);
    _friends[friendId] = (
      id: old.id,
      name: old.name,
      account: validateFriendAccount(bankCode, accountNumber),
    );
  }

  @override
  Future<void> close() async {}
}
