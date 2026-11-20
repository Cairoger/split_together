import 'dart:math';

import '../domain.dart';

final _random = Random.secure();

String newId() => List.generate(
  16,
  (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

abstract interface class SplitRepository {
  Future<AppData> load();
  Future<void> setDefaultName(String name);
  Future<void> setAppearance(AppAppearance value);
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

/// Each storage implementation applies these changes to the latest committed
/// group in one atomic operation, including checking current balances.
abstract class LedgerRepository implements SplitRepository {
  Future<void> writeName(String value);
  Future<String> insertGroup(Ledger Function(String selfName) build);
  Future<void> changeGroup(String id, Ledger Function(Ledger group) update);

  @override
  Future<void> setDefaultName(String name) async =>
      writeName(_text(name, '預設名稱'));

  @override
  Future<String> createGroup(
    String name,
    String category,
    List<String> others,
  ) => insertGroup((selfName) {
    final now = DateTime.now().toUtc();
    final names = [selfName, ...others.map((n) => _text(n, '成員名稱'))];
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
          ),
      ]),
      expenses: const [],
      repayments: const [],
    );
  });

  Future<void> _edit(String id, Ledger Function(Ledger) update) =>
      changeGroup(id, (group) {
        if (group.archived) throw const FormatException('請先解除封存再修改群組');
        return update(group);
      });

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
  Future<void> addMember(String groupId, String name) => _edit(groupId, (g) {
    final member = Member(
      id: newId(),
      name: _uniqueName(g, name),
      isSelf: false,
      isActive: true,
      createdAt: DateTime.now().toUtc(),
    );
    return _updated(g, members: [...g.members, member]);
  });

  @override
  Future<void> renameMember(String groupId, String memberId, String name) =>
      _edit(groupId, (g) {
        final old = _member(g, memberId);
        final renamed = Member(
          id: old.id,
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
