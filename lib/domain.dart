import 'dart:collection';
import 'dart:math' as math;

part 'quick_meal.dart';

enum SplitMethod { equal, exact, percent, weight }

class Member {
  const Member({
    required this.id,
    required this.name,
    required this.isSelf,
    required this.isActive,
    required this.createdAt,
    this.friendId,
  });

  final String id;
  final String name;
  final bool isSelf;
  final bool isActive;
  final DateTime createdAt;
  final String? friendId;
}

/// Bank accounts are strings so leading zeroes survive input, copy and storage.
String normalizeAccountNumber(String raw) {
  final digits = raw.replaceAll(RegExp(r'[\s-]'), '');
  if (!RegExp(r'^[0-9]{6,20}$').hasMatch(digits)) {
    throw const FormatException('收款帳號須為 6 至 20 位數字');
  }
  return digits;
}

class MemberDraft {
  const MemberDraft({
    required this.name,
    this.friendId,
    this.saveAsFriend = false,
    this.bankCode,
    this.accountNumber,
  });
  final String name;
  final String? friendId, bankCode, accountNumber;
  final bool saveAsFriend;
}

/// Only masked account information is included in the general app snapshot.
class SavedFriend {
  const SavedFriend({
    required this.id,
    required this.name,
    this.bankCode,
    this.lastFour,
    this.isArchived = false,
  });
  final String id, name;
  final bool isArchived;
  final String? bankCode, lastFour;
}

class BankAppChoice {
  const BankAppChoice({required this.id, required this.label});
  final String id, label;
}

class Expense {
  const Expense({
    required this.id,
    required this.title,
    required this.amount,
    required this.payerId,
    required this.method,
    required this.category,
    required this.spentAt,
    required this.note,
    required this.createdAt,
    required this.updatedAt,
    required this.shares,
    required this.inputs,
  });

  final String id;
  final String title;
  final int amount;
  final String payerId;
  final SplitMethod method;
  final String category;
  final DateTime spentAt;
  final String note;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, int> shares;
  final Map<String, int> inputs;
}

class Repayment {
  const Repayment({
    required this.id,
    required this.fromId,
    required this.toId,
    required this.amount,
    required this.paidAt,
    required this.note,
    required this.createdAt,
  });

  final String id;
  final String fromId;
  final String toId;
  final int amount;
  final DateTime paidAt;
  final String note;
  final DateTime createdAt;
}

class Ledger {
  const Ledger({
    required this.id,
    required this.name,
    required this.category,
    required this.archived,
    required this.createdAt,
    required this.updatedAt,
    required this.members,
    required this.expenses,
    required this.repayments,
  });

  final String id;
  final String name;
  final String category;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<Member> members;
  final List<Expense> expenses;
  final List<Repayment> repayments;

  Member get self => members.singleWhere((member) => member.isSelf);
  Member member(String id) => members.firstWhere((member) => member.id == id);
  int get totalExpense => expenses.fold(0, (sum, item) => sum + item.amount);

  Map<String, int> get expenseByCategory {
    final totals = <String, int>{};
    for (final expense in expenses) {
      totals.update(
        expense.category,
        (v) => v + expense.amount,
        ifAbsent: () => expense.amount,
      );
    }
    return totals;
  }
}

enum AppAppearance { light, dark }

class AppData {
  const AppData({
    required this.defaultName,
    required this.groups,
    this.appearance = AppAppearance.light,
    this.hasSeenExampleResult = false,
    this.friends = const [],
    this.bankApp,
    this.quickMeals = const [],
  });
  final String defaultName;
  final AppAppearance appearance;
  final bool hasSeenExampleResult;
  final List<SavedFriend> friends;
  final BankAppChoice? bankApp;
  final List<Ledger> groups;
  final List<QuickMeal> quickMeals;

  List<SavedFriend> get activeFriends =>
      friends.where((friend) => !friend.isArchived).toList();

  Map<String, String> get quickMealPeople {
    final sorted = activeFriends
      ..sort((a, b) {
        final byName = a.name.compareTo(b.name);
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    final nameCounts = <String, int>{defaultName: 1};
    for (final friend in sorted) {
      nameCounts.update(friend.name, (n) => n + 1, ifAbsent: () => 1);
    }
    final labels = <String, String>{quickMealSelfId: defaultName};
    final nextNumber = <String, int>{};
    for (final friend in sorted) {
      var label = friend.name;
      if (nameCounts[label]! > 1) {
        var number = nextNumber[label] ?? 1;
        // 使用者也可能真的把朋友取名為「小林（朋友 1）」。
        do {
          label = '${friend.name}（朋友 ${number++}）';
        } while (nameCounts.containsKey(label));
        nextNumber[friend.name] = number;
      }
      labels[friend.id] = label;
    }
    return labels;
  }
}

class Transfer {
  const Transfer({
    required this.fromId,
    required this.toId,
    required this.amount,
  });

  final String fromId;
  final String toId;
  final int amount;
}

String shortDate(DateTime date) {
  final local = date.toLocal();
  return '${local.year}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')}';
}

abstract final class Money {
  static const maxMinor = 9999999999;
  static final _decimal = RegExp(r'^([0-9]+)(?:\.([0-9]{1,2}))?$');

  static int parse(String value, {bool allowZero = false}) {
    final match = _decimal.firstMatch(value.trim());
    if (match == null) {
      throw const FormatException('請輸入非負金額，小數最多兩位。');
    }
    final whole = int.tryParse(match[1]!);
    if (whole == null || whole > maxMinor ~/ 100) {
      throw const FormatException(r'單筆金額最多為 NT$99,999,999.99。');
    }
    final fraction = (match[2] ?? '').padRight(2, '0');
    final minor = whole * 100 + int.parse(fraction);
    if (minor == 0 && !allowZero) {
      throw const FormatException('金額必須大於零。');
    }
    return minor;
  }

  static String _fraction(int absolute) {
    final cents = absolute % 100;
    return cents == 0 ? '' : '.${cents.toString().padLeft(2, '0')}';
  }

  static String input(int amount) {
    final absolute = amount.abs();
    return '${amount < 0 ? '-' : ''}${absolute ~/ 100}${_fraction(absolute)}';
  }

  static String format(int amount) {
    final absolute = amount.abs();
    final digits = (absolute ~/ 100).toString();
    final grouped = digits.replaceAllMapped(
      RegExp(r'[0-9](?=(?:[0-9]{3})+$)'),
      (match) => '${match[0]},',
    );
    return '${amount < 0 ? '-' : ''}NT\$$grouped${_fraction(absolute)}';
  }
}

abstract final class SplitService {
  static Map<String, int> divide(
    int amount,
    SplitMethod method,
    List<String> memberIds,
    Map<String, int> inputs,
  ) {
    if (amount <= 0 || amount > Money.maxMinor) {
      throw const FormatException('消費金額超出可輸入範圍。');
    }
    if (memberIds.isEmpty) {
      throw const FormatException('請至少選擇一位參與者。');
    }
    final ids = memberIds.toSet();
    if (ids.length != memberIds.length || ids.any((id) => id.trim().isEmpty)) {
      throw const FormatException('參與者無效或重複。');
    }
    if (method != SplitMethod.equal &&
        (inputs.length != ids.length || !ids.every(inputs.containsKey))) {
      throw const FormatException('請填寫每位參與者的分攤資料。');
    }

    if (method == SplitMethod.exact) {
      if (inputs.values.any((value) => value < 0 || value > Money.maxMinor)) {
        throw const FormatException('個人分攤金額超出可輸入範圍。');
      }
      final difference =
          amount - inputs.values.fold<int>(0, (sum, n) => sum + n);
      if (difference != 0) {
        final label = difference > 0 ? '尚差' : '超出';
        throw FormatException('分攤合計$label ${Money.format(difference.abs())}。');
      }
      return Map.of(inputs);
    }

    final weights = method == SplitMethod.equal
        ? {for (final id in ids) id: 1}
        : inputs;
    final denominator = weights.values.fold(0, (sum, n) => sum + n);
    if (method == SplitMethod.percent &&
        (denominator != 10000 ||
            weights.values.any((n) => n < 0 || n > 10000))) {
      throw const FormatException('各人百分比須介於 0 至 100%，且合計 100%。');
    }
    if (method == SplitMethod.weight &&
        weights.values.any((n) => n < 1 || n > 10000)) {
      throw const FormatException('每人的權重必須是 1 至 10000 的整數。');
    }

    final shares = <String, int>{};
    final remainders = <({String id, int remainder})>[];
    var left = amount;
    for (final entry in weights.entries) {
      final numerator = amount * entry.value;
      final whole = numerator ~/ denominator;
      shares[entry.key] = whole;
      left -= whole;
      remainders.add((id: entry.key, remainder: numerator % denominator));
    }
    remainders.sort((a, b) {
      final order = b.remainder.compareTo(a.remainder);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    for (var i = 0; i < left; i++) {
      final id = remainders[i].id;
      shares[id] = shares[id]! + 1;
    }
    return shares;
  }
}

abstract final class BalanceService {
  static Map<String, int> balances(Ledger group) {
    final result = {for (final member in group.members) member.id: 0};
    void credit(String memberId, int delta) {
      final prior = result[memberId];
      if (prior == null) throw const FormatException('紀錄含有不屬於此群組的成員。');
      result[memberId] = prior + delta;
    }

    for (final expense in group.expenses) {
      credit(expense.payerId, expense.amount);
      for (final share in expense.shares.entries) {
        credit(share.key, -share.value);
      }
    }
    for (final payment in group.repayments) {
      credit(payment.fromId, payment.amount);
      credit(payment.toId, -payment.amount);
    }
    return result;
  }

  static ({int receivable, int payable, int net}) overview(
    Iterable<Ledger> groups,
  ) {
    var receivable = 0;
    var payable = 0;
    for (final group in groups) {
      final balance = balances(group)[group.self.id]!;
      if (balance > 0) {
        receivable += balance;
      } else {
        payable -= balance;
      }
    }
    return (
      receivable: receivable,
      payable: payable,
      net: receivable - payable,
    );
  }
}

typedef _Position = ({String id, int amount});

abstract final class SettlementService {
  static int _largestFirst(_Position a, _Position b) {
    final order = b.amount.compareTo(a.amount);
    return order == 0 ? a.id.compareTo(b.id) : order;
  }

  static List<Transfer> suggest(Map<String, int> balances) {
    if (balances.values.fold(0, (sum, n) => sum + n) != 0) {
      throw const FormatException('群組餘額合計必須為零。');
    }
    final creditors = SplayTreeSet<_Position>(_largestFirst);
    final debtors = SplayTreeSet<_Position>(_largestFirst);
    for (final entry in balances.entries) {
      if (entry.value > 0) {
        creditors.add((id: entry.key, amount: entry.value));
      } else if (entry.value < 0) {
        debtors.add((id: entry.key, amount: -entry.value));
      }
    }
    final transfers = <Transfer>[];
    while (debtors.isNotEmpty) {
      final debtor = debtors.first;
      final creditor = creditors.first;
      debtors.remove(debtor);
      creditors.remove(creditor);
      final amount = math.min(debtor.amount, creditor.amount);
      transfers.add(
        Transfer(fromId: debtor.id, toId: creditor.id, amount: amount),
      );
      if (debtor.amount > amount) {
        debtors.add((id: debtor.id, amount: debtor.amount - amount));
      }
      if (creditor.amount > amount) {
        creditors.add((id: creditor.id, amount: creditor.amount - amount));
      }
    }
    return transfers;
  }
}
