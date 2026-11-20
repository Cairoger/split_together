import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:split_together/data/ledger_backup.dart';
import 'package:split_together/domain.dart';

final date = DateTime.utc(2020, 2, 29, 14, 30, 15, 123, 456);

AppData fixture() {
  final person = quickMealGuestId('meal', 1);
  return AppData(
    defaultName: '本機預設稱呼',
    appearance: AppAppearance.dark,
    bankApp: const BankAppChoice(id: 'test.local.bank', label: '虛構銀行'),
    friends: const [
      SavedFriend(
        id: 'f',
        name: '新名字',
        bankCode: '987',
        lastFour: '7654',
        isArchived: true,
      ),
      SavedFriend(id: 'f2', name: '新名字'),
    ],
    groups: [
      Ledger(
        id: 'group',
        name: '週末旅行',
        category: '旅遊',
        archived: true,
        createdAt: date,
        updatedAt: date,
        members: [
          Member(
            id: 'a',
            name: '我',
            isSelf: true,
            isActive: true,
            createdAt: date,
          ),
          Member(
            id: 'b',
            name: '當時的名字',
            isSelf: false,
            isActive: false,
            friendId: 'f',
            createdAt: date,
          ),
        ],
        expenses: [
          for (final (index, method, inputs) in [
            (0, SplitMethod.percent, {'a': 3333, 'b': 6667}),
            (1, SplitMethod.weight, {'a': 1, 'b': 10000}),
            (2, SplitMethod.equal, <String, int>{}),
            (3, SplitMethod.exact, {'a': 100, 'b': 1}),
          ])
            Expense(
              id: 'expense-$index',
              title: '車費',
              amount: 101,
              payerId: 'a',
              method: method,
              category: '交通',
              spentAt: date,
              note: '回程',
              createdAt: date,
              updatedAt: date,
              shares: SplitService.divide(101, method, ['a', 'b'], inputs),
              inputs: inputs,
            ),
        ],
        repayments: [
          Repayment(
            id: 'payment',
            fromId: 'b',
            toId: 'a',
            amount: 219,
            paidAt: date,
            note: '旅費',
            createdAt: date,
          ),
        ],
      ),
    ],
    quickMeals: [
      // 歷史結果直接保留原來的尾差歸屬。
      QuickMeal.recorded(
        id: 'meal',
        createdAt: date,
        total: 100,
        payerId: 'f',
        people: {quickMealSelfId: '我', 'f': '當時的名字', person: '訪客'},
        shares: {quickMealSelfId: 33, 'f': 34, person: 33},
      ),
    ],
  );
}

Future<List<int>> editDocument(
  Future<List<int>> original,
  void Function(Map<String, dynamic>) edit, {
  bool updateChecksum = true,
}) async {
  final json = jsonDecode(utf8.decode(await original)) as Map<String, dynamic>;
  edit(json);
  if (updateChecksum) {
    json.remove('sha256');
    final digest = await Sha256().hash(utf8.encode(jsonEncode(json)));
    json['sha256'] = digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
  return utf8.encode(jsonEncode(json));
}

void main() {
  late LedgerBackup backup;
  setUp(() => backup = LedgerBackup.fromData(fixture(), date));

  test('白名單排除銀行欄位、末四碼及裝置設定，保留封存朋友及同名不同 ID', () async {
    final bytes = await backup.encode();
    final json = jsonDecode(utf8.decode(bytes));
    expect(
      json['data'].keys,
      unorderedEquals(['friends', 'groups', 'quickMeals', 'currency']),
    );
    expect(
      json['data']['friends'][0].keys,
      unorderedEquals(['id', 'name', 'archived']),
    );
    for (final privateText in [
      'bankCode',
      'bank_code',
      'lastFour',
      'last_four',
      'cipher',
      'token',
      'test.local.bank',
      '本機預設稱呼',
      '7654',
    ]) {
      expect(utf8.decode(bytes), isNot(contains(privateText)));
    }
    final restored = (await LedgerBackup.decode(bytes)).data;
    expect(restored.friends.map((f) => f.id), ['f', 'f2']);
    expect(restored.activeFriends.single.id, 'f2');
    expect(restored.friends.first.bankCode, isNull);
    expect(restored.friends.first.lastFour, isNull);
    expect(restored.bankApp, isNull);
  });

  test('原始日期與微秒、四種分攤、還款、歷史姓名和聚餐尾差完整往返', () async {
    final snapshot = await LedgerBackup.decode(await backup.encode());
    final data = snapshot.data;
    final group = data.groups.single;
    final original = fixture().groups.single;
    expect(snapshot.createdAt, date);
    expect(group.createdAt, date);
    expect(group.archived, isTrue);
    expect(group.members.last.isActive, isFalse);
    expect(group.members.last.friendId, 'f');
    for (final (index, expense) in group.expenses.indexed) {
      final prior = original.expenses[index];
      expect(expense.spentAt, date);
      expect(expense.inputs, prior.inputs);
      expect(expense.shares, prior.shares);
      expect(expense.method, prior.method);
    }
    expect(group.repayments.single.paidAt, date);
    expect(BalanceService.balances(group), BalanceService.balances(original));
    expect(data.quickMeals.single.shares['f'], 34);
    expect(
      data.quickMeals.single.shareText,
      fixture().quickMeals.single.shareText,
    );
    expect(() => group.expenses.first.inputs.clear(), throwsUnsupportedError);
    expect(() => data.quickMeals.clear(), throwsUnsupportedError);
    expect(() => group.members.clear(), throwsUnsupportedError);
  });

  test('損毀的 UTF-8、摘要、沒有支援的版本及錯誤資料型別會被拒絕', () async {
    await expectLater(LedgerBackup.decode([255, 32]), throwsFormatException);
    for (final (key, value) in [
      ('sha256', 'bad'),
      ('version', 2),
      ('version', 1.0),
      ('format', ''),
    ]) {
      final bytes = await editDocument(
        backup.encode(),
        (doc) => doc[key] = value,
        updateChecksum: false,
      );
      await expectLater(LedgerBackup.decode(bytes), throwsFormatException);
    }
  });

  test('即使摘要正確，無效的日期、金額、比例、關聯、重複主鍵及額外欄位仍不能匯入', () async {
    final corruptions = <void Function(Map<String, dynamic>)>[
      (d) => d['createdAt'] = '2020-02-31T14:30:15.123456Z',
      (d) => d['data']['groups'][0]['expenses'][0]['payerId'] = 'missing',
      (d) => d['data']['groups'][0]['expenses'][0]['shares']['a'] += 1,
      (d) => d['data']['groups'][0]['expenses'][0]['amountMinor'] = 100.1,
      (d) => d['data']['groups'][0]['expenses'][0]['inputs']['b'] = 10000,
      (d) => d['data']['groups'][0]['repayments'][0]['amountMinor'] =
          Money.maxMinor + 1,
      (d) => d['data']['groups'][0]['members'][1]['friendId'] = 'orphan',
      (d) => d['data']['groups'][0]['members'][0]['self'] = false,
      (d) => d['data']['groups'][0]['repayments'][0]['toId'] = 'b',
      (d) => d['data']['friends'][1]['id'] = 'f',
      (d) => d['data']['friends'][0]['bankCode'] = '999',
      (d) => d['data']['friends'].removeAt(0),
      (d) => d['data']['quickMeals'][0]['people'].remove('f'),
      (d) => d['data']['quickMeals'][0]['id'] = 'different-meal',
    ];
    for (final corrupt in corruptions) {
      final bytes = await editDocument(backup.encode(), corrupt);
      await expectLater(LedgerBackup.decode(bytes), throwsFormatException);
    }
  });
}
