import '../domain.dart';
import 'repository.dart';

class MemorySplitRepository extends LedgerRepository {
  String _name = '我';
  AppAppearance _appearance = AppAppearance.light;
  final _groups = <String, Ledger>{};
  final _friends = <String, NewFriend>{};
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
          bankCode: f.account?.code,
          lastFour: f.account?.number.substring(f.account!.number.length - 4),
        ),
    ],
    groups: _groups.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
  );

  @override
  Future<String> createFriend(String name) async {
    final friend = newSavedFriend(name);
    _friends[friend.id] = friend;
    return friend.id;
  }

  @override
  Future<void> saveQuickMeal(QuickMeal meal) async {
    final saved = _quickMeals[meal.id];
    if (saved != null) {
      saved.verifyRetry(meal);
      return;
    }
    if (meal.people.keys.any(
      (id) => meal.needsSavedFriend(id) && !_friends.containsKey(id),
    )) {
      throw const FormatException('找不到常用朋友');
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
    _commitFriends(next, newFriends);
    _groups[id] = next;
  }

  void _commitFriends(Ledger group, List<NewFriend> additions) {
    final ids = {..._friends.keys, ...additions.map((f) => f.id)};
    if (group.members.any(
      (m) => m.friendId != null && !ids.contains(m.friendId),
    )) {
      throw const FormatException('找不到常用朋友');
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
