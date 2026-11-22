import 'dart:math';

import '../domain.dart';
import 'ledger_backup.dart';

final _random = Random.secure();

String newId() => List.generate(
  16,
  (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

const nonEmptyLedgerMessage = '本機已有帳目或常用朋友，只能在空帳本還原。';

abstract interface class SplitRepository {
  Future<AppData> load();
  Future<LedgerBackup> createBackup(DateTime createdAt);
  Future<bool> isLedgerEmpty();
  Future<void> restoreBackup(LedgerBackup backup);
  Future<String> createFriend(String name);
  Future<void> renameFriend(String id, String name);
  Future<void> archiveFriend(String id);
  Future<void> saveQuickMeal(QuickMeal meal);
  Future<void> setQuickMealPersonalExpense(String mealId, bool recorded);
  Future<void> setBankApp(BankAppChoice? choice);
  Future<void> setFriendAccount(
    String friendId,
    String? bankCode,
    String? accountNumber,
  );
  Future<String?> readFriendAccount(String friendId);
  Future<String> createGroupWithMembers(
    String name,
    String category,
    List<MemberDraft> members,
  );
  Future<void> addGroupMember(String groupId, MemberDraft member);
  Future<void> linkMemberFriend(
    String groupId,
    String memberId,
    MemberDraft draft,
  );
  Future<void> setDefaultName(String name);
  Future<void> setAppearance(AppAppearance value);
  Future<void> markExampleResultSeen();
  Future<String> createGroup(String name, String category, List<String> others);
  Future<void> editGroup(String groupId, String name, String category);
  Future<void> setArchived(String groupId, bool archived);
  Future<void> addMember(String groupId, String name);
  Future<void> renameMember(String groupId, String memberId, String name);
  Future<void> deactivateMember(String groupId, String memberId);
  Future<void> saveExpense(String groupId, Expense expense);
  Future<void> deleteExpense(String groupId, String expenseId);
  Future<void> addRepayment(String groupId, Repayment repayment);
  Future<void> deleteRepayment(String groupId, String repaymentId);
  Future<void> close();
}

typedef FriendAccount = ({String code, String number});
typedef NewFriend = ({String id, String name, FriendAccount? account});

String validateFriendName(String name) => _text(name, '朋友姓名');

NewFriend newSavedFriend(String name) =>
    (id: newId(), name: validateFriendName(name), account: null);

FriendAccount? validateFriendAccount(String? bankCode, String? accountNumber) {
  if (bankCode == null && accountNumber == null) return null;
  final code = bankCode?.trim() ?? '';
  if (!RegExp(r'^[0-9]{3}$').hasMatch(code)) {
    throw const FormatException('請輸入三位數銀行代碼');
  }
  return (code: code, number: normalizeAccountNumber(accountNumber ?? ''));
}

/// IDs are assigned before writing so the group, new friends and all links
/// can be committed together. Identical names never establish a link.
({String name, String? friendId}) _prepare(
  MemberDraft draft,
  List<NewFriend> newFriends,
) {
  final name = _text(draft.name, '成員名稱');
  final account = validateFriendAccount(draft.bankCode, draft.accountNumber);
  if (draft.friendId != null) {
    if (account != null) throw const FormatException('請從常用朋友資料修改收款帳號');
    return (name: name, friendId: _text(draft.friendId!, '朋友識別碼'));
  }
  if (!draft.saveAsFriend) {
    if (account != null) throw const FormatException('請先勾選存為常用朋友再儲存收款帳號');
    return (name: name, friendId: null);
  }
  final id = newId();
  newFriends.add((id: id, name: name, account: account));
  return (name: name, friendId: id);
}

/// Each storage implementation applies these changes to the latest committed
/// group in one atomic operation, including checking current balances.
abstract class LedgerRepository implements SplitRepository {
  Future<void> writeName(String value);
  Future<String> insertGroup(
    Ledger Function(String selfName) build, {
    List<NewFriend> newFriends = const [],
  });
  Future<void> changeGroup(
    String id,
    Ledger Function(Ledger group) update, {
    List<NewFriend> newFriends = const [],
  });

  @override
  Future<void> setDefaultName(String name) async =>
      writeName(_text(name, '預設名稱'));

  @override
  Future<String> createGroup(
    String name,
    String category,
    List<String> others,
  ) => createGroupWithMembers(name, category, [
    for (final other in others) MemberDraft(name: other),
  ]);

  @override
  Future<String> createGroupWithMembers(
    String name,
    String category,
    List<MemberDraft> members,
  ) async {
    final newFriends = <NewFriend>[];
    final others = [for (final member in members) _prepare(member, newFriends)];
    final linkedIds = others
        .map((m) => m.friendId)
        .whereType<String>()
        .toList();
    if (linkedIds.toSet().length != linkedIds.length) {
      throw const FormatException('這位朋友已經在群組中');
    }
    return insertGroup((selfName) {
      final now = DateTime.now().toUtc();
      final names = [selfName, ...others.map((m) => m.name)];
      if (names.toSet().length != names.length) {
        throw const FormatException('同一群組的成員名稱不可重複');
      }
      return Ledger(
        id: newId(),
        name: _text(name, '群組名稱'),
        category: _category(category),
        archived: false,
        createdAt: now,
        updatedAt: now,
        members: List.unmodifiable([
          for (final (index, memberName) in names.indexed)
            Member(
              id: newId(),
              name: memberName,
              isSelf: index == 0,
              isActive: true,
              createdAt: now,
              friendId: index == 0 ? null : others[index - 1].friendId,
            ),
        ]),
        expenses: const [],
        repayments: const [],
      );
    }, newFriends: newFriends);
  }

  Future<void> _edit(
    String id,
    Ledger Function(Ledger) update, {
    List<NewFriend> newFriends = const [],
  }) => changeGroup(id, (group) {
    if (group.archived) throw const FormatException('請先解除封存再修改群組');
    return update(group);
  }, newFriends: newFriends);

  @override
  Future<void> editGroup(String groupId, String name, String category) => _edit(
    groupId,
    (g) =>
        _updated(g, name: _text(name, '群組名稱'), category: _category(category)),
  );

  @override
  Future<void> setArchived(String groupId, bool archived) =>
      changeGroup(groupId, (group) {
        if (archived &&
            BalanceService.balances(group).values.any((b) => b != 0)) {
          throw const FormatException('請先結清所有餘額再封存群組');
        }
        return _updated(group, archived: archived);
      });

  @override
  Future<void> addMember(String groupId, String name) =>
      addGroupMember(groupId, MemberDraft(name: name));

  @override
  Future<void> addGroupMember(String groupId, MemberDraft draft) async {
    final newFriends = <NewFriend>[];
    final prepared = _prepare(draft, newFriends);
    return _edit(groupId, (g) {
      _checkLink(g, prepared.friendId);
      final member = Member(
        id: newId(),
        name: _uniqueName(g, prepared.name),
        isSelf: false,
        isActive: true,
        createdAt: DateTime.now().toUtc(),
        friendId: prepared.friendId,
      );
      return _updated(g, members: [...g.members, member]);
    }, newFriends: newFriends);
  }

  @override
  Future<void> linkMemberFriend(
    String groupId,
    String memberId,
    MemberDraft draft,
  ) async {
    final newFriends = <NewFriend>[];
    final prepared = _prepare(draft, newFriends);
    if (prepared.friendId == null) throw const FormatException('請選擇或建立常用朋友');
    return _edit(groupId, (g) {
      final old = _member(g, memberId);
      if (old.isSelf) throw const FormatException('本人不能連結為常用朋友');
      if (old.friendId != null && old.friendId != prepared.friendId) {
        throw const FormatException('此成員已連結其他朋友');
      }
      _checkLink(g, prepared.friendId, except: memberId);
      final linked = Member(
        id: old.id,
        name: old.name,
        isSelf: old.isSelf,
        isActive: old.isActive,
        createdAt: old.createdAt,
        friendId: prepared.friendId,
      );
      return _updated(
        g,
        members: [for (final m in g.members) m.id == old.id ? linked : m],
      );
    }, newFriends: newFriends);
  }

  @override
  Future<void> renameMember(String groupId, String memberId, String name) =>
      _edit(groupId, (g) {
        final old = _member(g, memberId);
        final renamed = Member(
          id: old.id,
          friendId: old.friendId,
          name: _uniqueName(g, name, except: old.id),
          isSelf: old.isSelf,
          isActive: old.isActive,
          createdAt: old.createdAt,
        );
        return _updated(
          g,
          members: [for (final m in g.members) m.id == memberId ? renamed : m],
        );
      });

  @override
  Future<void> deactivateMember(String groupId, String memberId) =>
      _edit(groupId, (g) {
        final old = _member(g, memberId);
        if (old.isSelf) throw const FormatException('不能停用「我」');
        if (BalanceService.balances(g)[memberId] != 0) {
          throw const FormatException('成員還有未結清餘額');
        }
        final inactive = Member(
          id: old.id,
          friendId: old.friendId,
          name: old.name,
          isSelf: false,
          isActive: false,
          createdAt: old.createdAt,
        );
        return _updated(
          g,
          members: [for (final m in g.members) m.id == memberId ? inactive : m],
        );
      });

  @override
  Future<void> saveExpense(String groupId, Expense expense) => _edit(groupId, (
    g,
  ) {
    final previous = g.expenses.where((e) => e.id == expense.id).firstOrNull;
    _text(expense.id, '消費識別碼');
    final title = _text(expense.title, '消費名稱');
    final category = _text(expense.category, '消費分類');
    final payer = _member(g, expense.payerId);
    if (!payer.isActive && previous?.payerId != payer.id) {
      throw const FormatException('請選擇有效的付款人');
    }
    for (final id in expense.shares.keys) {
      if (!_member(g, id).isActive &&
          !(previous?.shares.containsKey(id) ?? false)) {
        throw const FormatException('請選擇有效的參與者');
      }
    }
    final shares = SplitService.divide(
      expense.amount,
      expense.method,
      expense.shares.keys.toList(),
      expense.inputs,
    );
    if (shares.entries.any((s) => expense.shares[s.key] != s.value)) {
      throw const FormatException('分帳預覽與計算結果不符，請重新確認');
    }
    final saved = Expense(
      id: expense.id,
      title: title,
      amount: expense.amount,
      payerId: payer.id,
      method: expense.method,
      category: category,
      spentAt: expense.spentAt.toUtc(),
      note: expense.note,
      createdAt: previous?.createdAt ?? expense.createdAt.toUtc(),
      updatedAt: DateTime.now().toUtc(),
      shares: Map.unmodifiable(shares),
      inputs: expense.method == SplitMethod.equal
          ? const {}
          : Map.unmodifiable(expense.inputs),
    );
    return _updated(
      g,
      expenses: [saved, ...g.expenses.where((e) => e.id != saved.id)]
        ..sort((a, b) => b.spentAt.compareTo(a.spentAt)),
    );
  });

  @override
  Future<void> deleteExpense(String groupId, String expenseId) =>
      _edit(groupId, (g) {
        if (!g.expenses.any((e) => e.id == expenseId)) {
          throw const FormatException('找不到這筆消費');
        }
        return _updated(
          g,
          expenses: g.expenses.where((e) => e.id != expenseId).toList(),
        );
      });

  @override
  Future<void> addRepayment(String groupId, Repayment repayment) =>
      _edit(groupId, (g) {
        _text(repayment.id, '還款識別碼');
        if (g.repayments.any((r) => r.id == repayment.id)) {
          throw const FormatException('這筆還款已經記錄');
        }
        _member(g, repayment.fromId);
        _member(g, repayment.toId);
        final balances = BalanceService.balances(g);
        if (repayment.fromId == repayment.toId ||
            balances[repayment.fromId]! >= 0 ||
            balances[repayment.toId]! <= 0) {
          throw const FormatException('請選擇仍有應付及應收餘額的不同成員');
        }
        if (repayment.amount <= 0 ||
            repayment.amount > Money.maxMinor ||
            repayment.amount > -balances[repayment.fromId]! ||
            repayment.amount > balances[repayment.toId]!) {
          throw const FormatException('還款金額必須大於零且在可結算金額與單筆上限內');
        }
        return _updated(
          g,
          repayments: [repayment, ...g.repayments]
            ..sort((a, b) => b.paidAt.compareTo(a.paidAt)),
        );
      });

  @override
  Future<void> deleteRepayment(String groupId, String repaymentId) =>
      _edit(groupId, (g) {
        if (!g.repayments.any((r) => r.id == repaymentId)) {
          throw const FormatException('找不到這筆還款');
        }
        return _updated(
          g,
          repayments: g.repayments.where((r) => r.id != repaymentId).toList(),
        );
      });
}

void _checkLink(Ledger group, String? friendId, {String? except}) {
  if (friendId != null &&
      group.members.any((m) => m.id != except && m.friendId == friendId)) {
    throw const FormatException('這位朋友已經在群組中');
  }
}

String _text(String input, String label) {
  final value = input.trim();
  if (value.isEmpty) throw FormatException('請填寫$label');
  return value;
}

String _category(String value) {
  if (!const {'旅遊', '聚餐', '生活', '其他'}.contains(value)) {
    throw const FormatException('請選擇有效的群組類型');
  }
  return value;
}

Member _member(Ledger g, String id) => g.members.firstWhere(
  (member) => member.id == id,
  orElse: () => throw const FormatException('找不到此群組的成員'),
);

String _uniqueName(Ledger g, String input, {String? except}) {
  final name = _text(input, '成員名稱');
  if (g.members.any((member) => member.name == name && member.id != except)) {
    throw const FormatException('同一群組的成員名稱不可重複');
  }
  return name;
}

Ledger _updated(
  Ledger g, {
  String? name,
  String? category,
  bool? archived,
  List<Member>? members,
  List<Expense>? expenses,
  List<Repayment>? repayments,
}) => Ledger(
  id: g.id,
  name: name ?? g.name,
  category: category ?? g.category,
  archived: archived ?? g.archived,
  createdAt: g.createdAt,
  updatedAt: DateTime.now().toUtc(),
  members: members == null ? g.members : List.unmodifiable(members),
  expenses: expenses == null ? g.expenses : List.unmodifiable(expenses),
  repayments: repayments == null ? g.repayments : List.unmodifiable(repayments),
);
