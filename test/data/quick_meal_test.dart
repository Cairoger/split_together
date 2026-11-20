import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:split_together/data/account_cipher.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/data/repository.dart';
import 'package:split_together/data/schema.dart';
import 'package:split_together/data/sqlite_repository.dart';
import 'package:split_together/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final date = DateTime(2026, 11, 12, 0, 30).toUtc();

QuickMeal meal(
  Map<String, String> people,
  String payer,
  int total, {
  String id = 'meal',
}) => QuickMeal(
  id: id,
  createdAt: date,
  total: total,
  payerId: payer,
  people: people,
);

void main() {
  sqfliteFfiInit();
  test('四人一桌平分時，付款人負擔自己的一份，只有其他三人要轉帳', () {
    final people = {quickMealSelfId: '我', 'b': '小林', 'c': '小陳', 'd': '小李'};
    final receipt = meal(people, 'b', 120000);
    expect(receipt.shares.values, everyElement(30000));
    expect(
      receipt.transfers.map((t) => t.fromId),
      unorderedEquals([quickMealSelfId, 'c', 'd']),
    );
    expect(
      receipt.transfers.every((t) => t.toId == 'b' && t.amount == 30000),
      isTrue,
    );
    expect(receipt.shareText, r'''2026/11/12 聚餐分帳
總額 NT$1,200｜4 人平分（每人 NT$300）
付款人：小林

我 → 小林　NT$300
小陳 → 小林　NT$300
小李 → 小林　NT$300''');
    people.clear();
    expect(receipt.people, hasLength(4));
  });

  test('三人平分一千元，尾差依穩定 ID 分配；極小金額不產生零元轉帳', () {
    final first = meal({'z': '甲', 'a': '甲', 'm': '丙'}, 'm', 100000);
    final second = meal({'a': '甲', 'm': '丙', 'z': '甲'}, 'z', 100000);
    expect(first.shares, {'a': 33334, 'm': 33333, 'z': 33333});
    expect(second.shares, first.shares);
    expect(first.shares.values.reduce((a, b) => a + b), 100000);
    final tiny = meal(first.people, 'a', 1);
    expect(tiny.transfers, isEmpty);
    expect(tiny.shareText, r'''2026/11/12 聚餐分帳
總額 NT$0.01｜3 人平分
付款人：甲

本次無須轉帳''');
    expect(() => meal({'a': '甲'}, 'a', 100), throwsFormatException);
    expect(() => meal(first.people, '缺席', 100), throwsFormatException);
    expect(() => meal(first.people, 'a', 0), throwsFormatException);
  });

  test('從紀錄分享尾差時逐筆使用原分攤，不宣稱每人金額相同', () {
    final receipt = QuickMeal.recorded(
      id: 'dinner',
      createdAt: date,
      total: 100000,
      people: {'a': '小晴', 'b': '小安', 'c': '小林'},
      payerId: 'c',
      shares: {'a': 33333, 'b': 33334, 'c': 33333},
    );
    expect(receipt.shareText, r'''2026/11/12 聚餐分帳
總額 NT$1,000｜3 人平分
付款人：小林

小安 → 小林　NT$333.34
小晴 → 小林　NT$333.33''');
  });

  for (final sqlite in [false, true]) {
    test('${sqlite ? 'SQLite' : '記憶體'} 臨時參與者只留在該餐，不寫入常用朋友', () async {
      final SplitRepository repo = sqlite
          ? SqliteSplitRepository(
              factory: databaseFactoryFfi,
              path: inMemoryDatabasePath,
            )
          : MemorySplitRepository();
      addTearDown(repo.close);
      final guestId = quickMealGuestId('dinner', 1);
      final secondGuestId = quickMealGuestId('dinner', 2);
      final snapshot = meal(
        {quickMealSelfId: '我', guestId: '小林', secondGuestId: '小林（臨時 1）'},
        guestId,
        90000,
        id: 'dinner',
      );
      await repo.saveQuickMeal(snapshot);
      await repo.saveQuickMeal(snapshot);
      final data = await repo.load();
      expect(data.friends, isEmpty);
      expect(data.groups, isEmpty);
      expect(data.quickMealPeople.keys, [quickMealSelfId]);
      expect(data.quickMeals.single.people, snapshot.people);
      expect(data.quickMeals.single.payerId, guestId);
      expect(data.quickMeals.single.transfers, hasLength(2));
      await expectLater(
        repo.saveQuickMeal(meal(snapshot.people, guestId, 90000, id: 'next')),
        throwsFormatException,
      );
      expect((await repo.load()).quickMeals, hasLength(1));
    });

    test('${sqlite ? 'SQLite' : '記憶體'} 以朋友 ID 區別同名、重送只存一次、每餐獨立', () async {
      final SplitRepository repo = sqlite
          ? SqliteSplitRepository(
              factory: databaseFactoryFfi,
              path: inMemoryDatabasePath,
            )
          : MemorySplitRepository();
      addTearDown(repo.close);
      await expectLater(repo.createFriend('  '), throwsFormatException);
      final a = await repo.createFriend('小林');
      final b = await repo.createFriend(' 小林 ');
      final c = await repo.createFriend('小林（朋友 1）');
      final collision = await repo.createFriend('我');
      final data = await repo.load();
      expect(data.groups, isEmpty);
      final all = data.quickMealPeople;
      expect(all.values.toSet().length, 5);
      expect(all[quickMealSelfId], '我');
      expect(all[collision], isNot('我'));
      final first = meal({a: all[a]!, b: all[b]!, c: all[c]!}, a, 100000);
      await Future.wait([repo.saveQuickMeal(first), repo.saveQuickMeal(first)]);
      expect((await repo.load()).quickMeals.single.shares, first.shares);
      await expectLater(
        repo.saveQuickMeal(meal(first.people, a, 123)),
        throwsFormatException,
      );
      await expectLater(
        repo.saveQuickMeal(meal({a: '小林', 'missing': '缺少'}, a, 123, id: '無效')),
        throwsFormatException,
      );

      final second = meal(
        {quickMealSelfId: '我', b: all[b]!},
        b,
        20000,
        id: 'meal2',
      );
      final repeat = meal(first.people, a, first.total, id: 'meal3');
      await repo.saveQuickMeal(second);
      await repo.saveQuickMeal(repeat);
      final after = await repo.load();
      expect(after.quickMeals, hasLength(3));
      final changed = after.quickMeals.singleWhere((m) => m.id == 'meal2');
      expect(changed.people.keys, unorderedEquals([quickMealSelfId, b]));
      expect(changed.transfers.single.fromId, quickMealSelfId);
      expect(changed.transfers.single.toId, b);
      expect(changed.transfers.single.amount, 10000);
      expect(after.groups, isEmpty);
    });
  }

  test('v2 遷移保留收款帳號、銀行偏好、消費及還款；聚餐交易失敗可重試，重開讀回結果', () async {
    final directory = await Directory.systemTemp.createTemp('split-meals-');
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'ledger.db');
    final key = await AesGcm.with256bits().newSecretKey();
    final cipher = AccountCipher(loadKey: (_) async => key);
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, v) => migrateLedger(db, 0, v),
      ),
    );
    const number = '000019876543';
    final encrypted = await cipher.encrypt(
      'old-friend',
      '700',
      number,
      canCreateKey: true,
    );
    await old.insert('friends', {
      'id': 'old-friend',
      'name': '小林',
      'bank_code': '700',
      'last_four': '6543',
      'account_cipher': encrypted,
    });
    final time = date.toIso8601String();
    await old.insert('groups', {
      'id': 'g',
      'name': '舊帳本',
      'category': '聚餐',
      'is_archived': 0,
      'created_at': time,
      'updated_at': time,
    });
    for (final member in ['self', 'guest']) {
      await old.insert('members', {
        'group_id': 'g',
        'id': member,
        'name': member,
        'is_self': member == 'self' ? 1 : 0,
        'is_active': 1,
        'created_at': time,
        'friend_id': member == 'guest' ? 'old-friend' : null,
      });
    }
    await old.insert('expenses', {
      'group_id': 'g',
      'id': 'e',
      'title': '舊餐費',
      'amount_minor': 8000,
      'payer_member_id': 'self',
      'split_method': 'equal',
      'category': '餐飲',
      'spent_at': time,
      'note': '',
      'created_at': time,
      'updated_at': time,
    });
    await old.insert('expense_splits', {
      'expense_id': 'e',
      'group_id': 'g',
      'member_id': 'guest',
      'amount_minor': 8000,
    });
    await old.insert('settlements', {
      'id': 'r',
      'group_id': 'g',
      'from_member_id': 'guest',
      'to_member_id': 'self',
      'amount_minor': 3000,
      'paid_at': time,
      'note': '部分還款',
      'created_at': time,
    });
    for (final entry in {
      'default_name': '本人',
      'appearance': 'dark',
      'bank_app': '{"id":"test.app","label":"測試銀行"}',
    }.entries) {
      await old.insert('app_settings', {
        'key': entry.key,
        'value': entry.value,
      });
    }
    await old.close();
    SqliteSplitRepository open() => SqliteSplitRepository(
      factory: databaseFactoryFfi,
      path: path,
      accountCipher: cipher,
    );
    var repo = open();
    addTearDown(() => repo.close());
    final upgraded = await repo.load();
    expect(upgraded.quickMeals, isEmpty);
    expect(upgraded.defaultName, '本人');
    expect(upgraded.appearance, AppAppearance.dark);
    expect(upgraded.bankApp?.id, 'test.app');
    expect(upgraded.friends.single.lastFour, '6543');
    expect(await repo.readFriendAccount('old-friend'), number);
    final receipt = meal(upgraded.quickMealPeople, 'old-friend', 60000);
    final db = await databaseFactoryFfi.openDatabase(path);
    expect(await db.getVersion(), 4);
    await db.execute(
      """CREATE TRIGGER reject_attendee BEFORE INSERT ON quick_meal_people
      WHEN NEW.person_id = 'old-friend' BEGIN SELECT RAISE(ABORT, '測試資料寫入失敗'); END""",
    );
    await expectLater(
      repo.saveQuickMeal(receipt),
      throwsA(isA<DatabaseException>()),
    );
    expect(await db.query('quick_meals'), isEmpty);
    expect(await db.query('quick_meal_people'), isEmpty);
    await db.execute('DROP TRIGGER reject_attendee');
    await repo.saveQuickMeal(receipt);
    await repo.setDefaultName('新的本人名稱');
    await repo.close();
    repo = open();
    final loaded = await repo.load();
    final result = loaded.quickMeals.single;
    expect(result.id, receipt.id);
    expect(result.createdAt, receipt.createdAt);
    expect(result.shares, receipt.shares);
    expect(result.shareText, receipt.shareText);
    expect(result.shareText, contains('本人'));
    for (final sensitive in [number, '6543', '700', 'test.app']) {
      expect(result.shareText, isNot(contains(sensitive)));
    }
    final ledger = loaded.groups.single;
    expect(ledger.expenses.single.id, 'e');
    expect(ledger.repayments.single.id, 'r');
    expect(ledger.member('guest').friendId, 'old-friend');
    expect(BalanceService.balances(ledger), {'self': 5000, 'guest': -5000});
    await repo.saveQuickMeal(receipt);
    expect((await repo.load()).quickMeals, hasLength(1));
    expect(await repo.readFriendAccount('old-friend'), number);
  });
}
