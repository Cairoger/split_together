import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

// Synthetic fixtures only. Generate a fresh encryption key for each test.
const fixtureNumber = '000123456789';
const guest = MemberDraft(
  name: '乙',
  saveAsFriend: true,
  bankCode: '007',
  accountNumber: '0001-2345 6789',
);

void main() {
  sqfliteFfiInit();
  late AccountCipher cipher;
  setUp(() async {
    final key = await AesGcm.with256bits().newSecretKey();
    cipher = AccountCipher(loadKey: (_) async => key);
  });
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite 朋友' : '記憶體朋友', () {
      late SplitRepository repo;
      setUp(() {
        repo = sqlite
            ? SqliteSplitRepository(
                factory: databaseFactoryFfi,
                path: inMemoryDatabasePath,
                accountCipher: cipher,
              )
            : MemorySplitRepository();
      });
      tearDown(() => repo.close());

      test('改名與移出名單保留聚餐、既有群組及收款資料', () async {
        final groupId = await repo.createGroupWithMembers('晚餐', '聚餐', [guest]);
        final before = await repo.load();
        final id = before.activeFriends.single.id;
        final member = before.groups.single.members.singleWhere(
          (m) => !m.isSelf,
        );
        final sameName = await repo.createFriend('  小安  ');
        final now = DateTime.utc(2026, 11, 20);
        final meal = QuickMeal(
          id: '舊聚餐',
          createdAt: now,
          total: 10001,
          payerId: id,
          people: {quickMealSelfId: '我', id: '乙'},
        );
        await repo.saveQuickMeal(meal);

        final self = before.groups.single.self.id;
        await repo.saveExpense(
          groupId,
          Expense(
            id: '餐費',
            title: '餐費',
            amount: 6000,
            payerId: member.id,
            method: SplitMethod.equal,
            category: '餐飲',
            spentAt: now,
            note: '',
            createdAt: now,
            updatedAt: now,
            shares: {self: 3000, member.id: 3000},
            inputs: const {},
          ),
        );
        await repo.addRepayment(
          groupId,
          Repayment(
            id: '還款',
            fromId: self,
            toId: member.id,
            amount: 1500,
            paidAt: now,
            note: '',
            createdAt: now,
          ),
        );
        await expectLater(repo.createFriend('  '), throwsFormatException);
        await expectLater(repo.renameFriend(id, '  '), throwsFormatException);
        expect((await repo.load()).quickMealPeople[id], '乙');
        await repo.renameFriend(id, '  小安  ');
        final renamed = await repo.load();
        expect(renamed.activeFriends.map((f) => f.name), everyElement('小安'));
        expect(
          renamed.activeFriends.map((f) => f.id),
          unorderedEquals([id, sameName]),
        );
        expect(
          renamed.quickMealPeople[id],
          isNot(renamed.quickMealPeople[sameName]),
        );

        await repo.archiveFriend(id);
        final data = await repo.load();
        expect(data.activeFriends.single.id, sameName);
        expect(data.quickMealPeople, {quickMealSelfId: '我', sameName: '小安'});
        expect(data.friends.singleWhere((f) => f.id == id).isArchived, isTrue);
        expect(await repo.readFriendAccount(id), fixtureNumber);
        final history = data.quickMeals.single;
        expect(history.id, meal.id);
        expect(history.people, meal.people);
        expect(history.payerId, id);
        expect(history.shares, meal.shares);
        expect(history.shareText, meal.shareText);
        final ledger = data.groups.single;
        expect(ledger.member(member.id).name, '乙');
        expect(ledger.member(member.id).friendId, id);
        expect(ledger.member(member.id).isActive, isTrue);
        expect(ledger.repayments.single.amount, 1500);
        expect(ledger.expenses.single.shares, {self: 3000, member.id: 3000});
        expect(BalanceService.balances(ledger), {self: -1500, member.id: 1500});
        await repo.renameMember(groupId, member.id, '餐友乙');
        await repo.saveQuickMeal(meal); // 舊餐重試應保留原本的單筆交易。
        await expectLater(
          repo.saveQuickMeal(
            QuickMeal(
              id: '新聚餐',
              createdAt: now,
              total: meal.total,
              payerId: id,
              people: meal.people,
            ),
          ),
          throwsFormatException,
        );
        await expectLater(
          repo.createGroupWithMembers('新群組', '聚餐', [
            MemberDraft(name: '乙', friendId: id),
          ]),
          throwsFormatException,
        );
        final otherGroup = await repo.createGroup('另一群組', '其他', ['未連結成員']);
        final otherMember = (await repo.load()).groups
            .singleWhere((g) => g.id == otherGroup)
            .members
            .singleWhere((m) => !m.isSelf);
        await expectLater(
          repo.linkMemberFriend(
            otherGroup,
            otherMember.id,
            MemberDraft(name: '乙', friendId: id),
          ),
          throwsFormatException,
        );
        expect((await repo.load()).quickMeals.single.id, meal.id);
      });

      test('同名不自動連結，明確選定的朋友跨組共用收款資料', () async {
        final firstId = await repo.createGroupWithMembers('第一組', '其他', [guest]);
        final first = (await repo.load()).friends.single;
        expect(first.bankCode, '007');
        expect(first.lastFour, '6789');
        expect(await repo.readFriendAccount(first.id), fixtureNumber);

        final secondId = await repo.createGroupWithMembers('第二組', '生活', [
          const MemberDraft(name: '乙', saveAsFriend: true),
          MemberDraft(name: '同事乙', friendId: first.id),
        ]);
        final second = (await repo.load()).groups.singleWhere(
          (g) => g.id == secondId,
        );
        expect(
          second.members.singleWhere((m) => m.name == '乙').friendId,
          isNot(first.id),
        );
        final linked = second.members.singleWhere((m) => m.name == '同事乙');
        expect(linked.friendId, first.id);
        await repo.renameMember(secondId, linked.id, '乙同事');
        await repo.deactivateMember(secondId, linked.id);
        await repo.setFriendAccount(first.id, ' 812 ', '00 9988-7766');
        final data = await repo.load();
        expect(
          data.groups
              .singleWhere((g) => g.id == secondId)
              .member(linked.id)
              .friendId,
          first.id,
        );
        expect(
          data.groups.singleWhere((g) => g.id == firstId).members.last.friendId,
          first.id,
        );
        expect(
          data.friends.singleWhere((f) => f.id == first.id).lastFour,
          '7766',
        );
        expect(await repo.readFriendAccount(first.id), '0099887766');
        await repo.setFriendAccount(first.id, null, null);
        expect(await repo.readFriendAccount(first.id), isNull);
        final cleared = (await repo.load()).friends.singleWhere(
          (f) => f.id == first.id,
        );
        expect(cleared.bankCode, isNull);
        expect(cleared.lastFour, isNull);
      });

      test('既有成員可連結，拒絕重複與錯誤資料並回滾新增的朋友', () async {
        final g = await repo.createGroup('舊群組', '生活', ['舊名字']);
        final member = (await repo.load()).groups.single.members.last;
        await repo.linkMemberFriend(g, member.id, guest);
        var data = await repo.load();
        final friend = data.friends.single;
        final original = data.groups.single.member(member.id);
        expect(original.name, '舊名字');
        expect(original.friendId, friend.id);
        await expectLater(
          repo.addGroupMember(
            g,
            MemberDraft(name: '另一個名字', friendId: friend.id),
          ),
          throwsFormatException,
        );
        await expectLater(
          repo.linkMemberFriend(
            g,
            member.id,
            const MemberDraft(name: '丙', saveAsFriend: true),
          ),
          throwsFormatException,
        );
        await expectLater(
          repo.createGroupWithMembers('無效', '其他', [
            guest,
            const MemberDraft(name: '丙', friendId: 'missing'),
          ]),
          throwsFormatException,
        );
        await expectLater(
          repo.setFriendAccount(friend.id, '12', '1234567'),
          throwsFormatException,
        );
        await expectLater(
          repo.setFriendAccount(friend.id, '012', '12XY3'),
          throwsFormatException,
        );
        await expectLater(
          repo.setFriendAccount(friend.id, null, '12345678'),
          throwsFormatException,
        );
        await repo.setArchived(g, true);
        await expectLater(repo.addGroupMember(g, guest), throwsFormatException);
        data = await repo.load();
        expect(data.friends, hasLength(1));
        expect(data.groups, hasLength(1));
        expect(data.groups.single.members, hasLength(2));
        expect(await repo.readFriendAccount(friend.id), fixtureNumber);
      });
    });
  }

  test('v3 升級後朋友預設在名單中，重開仍保留封存狀態、收款資料與原餐紀錄', () async {
    final tmp = await Directory.systemTemp.createTemp('split-friends-v3-');
    addTearDown(() => tmp.delete(recursive: true));
    final location = p.join(tmp.path, 'ledger.db');
    final old = await databaseFactoryFfi.openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: 3,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) => migrateLedger(db, 0, version),
      ),
    );
    final encrypted = await cipher.encrypt(
      'lin',
      '007',
      fixtureNumber,
      canCreateKey: true,
    );
    await old.transaction((tx) async {
      await tx.insert('friends', {
        'id': 'lin',
        'name': '小林',
        'bank_code': '007',
        'last_four': '6789',
        'account_cipher': encrypted,
      });
      await tx.insert('quick_meals', {
        'id': 'meal',
        'created_at': 1000000,
        'total_minor': 101,
        'payer_id': 'lin',
      });
      for (final (id, name, share) in [
        (quickMealSelfId, '我', 51),
        ('lin', '小林', 50),
      ]) {
        await tx.insert('quick_meal_people', {
          'meal_id': 'meal',
          'person_id': id,
          'name': name,
          'share_minor': share,
        });
      }
    });
    await old.close();

    SqliteSplitRepository open() => SqliteSplitRepository(
      factory: databaseFactoryFfi,
      path: location,
      accountCipher: cipher,
    );
    var repo = open();
    addTearDown(() => repo.close());
    final upgraded = await repo.load();
    expect(upgraded.activeFriends.single.name, '小林');
    expect(upgraded.quickMeals.single.total, 101);
    await repo.renameFriend('lin', '小林同學');
    await repo.archiveFriend('lin');
    await repo.close();
    repo = open();
    final restored = await repo.load();
    expect(restored.friends.single.name, '小林同學');
    expect(restored.friends.single.isArchived, isTrue);
    expect(restored.activeFriends, isEmpty);
    expect(await repo.readFriendAccount('lin'), fixtureNumber);
    final meal = restored.quickMeals.single;
    expect(meal.people, {quickMealSelfId: '我', 'lin': '小林'});
    expect(meal.payerId, 'lin');
    expect(meal.shares, {quickMealSelfId: 51, 'lin': 50});
    expect(meal.transfers.single.amount, 51);
    final db = await databaseFactoryFfi.openDatabase(location);
    expect(await db.getVersion(), ledgerSchemaVersion);
    expect(
      (await db.query('friends')).single['account_cipher'],
      orderedEquals(encrypted),
    );
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('v1 原地升級；重開保留帳目、遮罩資料、銀行 App 與可解密帳號', () async {
    final tmp = await Directory.systemTemp.createTemp('split-friends-');
    addTearDown(() => tmp.delete(recursive: true));
    final location = p.join(tmp.path, 'ledger.db');
    final old = await databaseFactoryFfi.openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, v) => migrateLedger(db, 0, v),
      ),
    );
    final now = DateTime.utc(2026, 8, 1).toIso8601String();
    await old.insert('groups', {
      'id': 'g',
      'name': '旅遊',
      'category': '旅遊',
      'is_archived': 0,
      'created_at': now,
      'updated_at': now,
    });
    for (final id in ['a', 'b']) {
      await old.insert('members', {
        'id': id,
        'group_id': 'g',
        'name': id,
        'is_self': id == 'a' ? 1 : 0,
        'is_active': 1,
        'created_at': now,
      });
    }
    await old.insert('expenses', {
      'id': 'e',
      'group_id': 'g',
      'title': '車票',
      'amount_minor': 2222,
      'payer_member_id': 'a',
      'split_method': 'equal',
      'category': '交通',
      'spent_at': now,
      'note': '',
      'created_at': now,
      'updated_at': now,
    });
    await old.insert('expense_splits', {
      'expense_id': 'e',
      'group_id': 'g',
      'member_id': 'b',
      'amount_minor': 2222,
    });
    await old.close();

    SqliteSplitRepository open() => SqliteSplitRepository(
      factory: databaseFactoryFfi,
      path: location,
      accountCipher: cipher,
    );
    var repo = open();
    addTearDown(() => repo.close());
    final migrated = await repo.load();
    expect(migrated.groups.single.member('b').friendId, isNull);
    expect(migrated.friends, isEmpty);
    expect(migrated.bankApp, isNull);
    await repo.linkMemberFriend('g', 'b', guest);
    await repo.setBankApp(
      const BankAppChoice(id: 'app:example', label: '測試 App'),
    );
    await repo.close();
    repo = open();
    final data = await repo.load();
    expect(BalanceService.balances(data.groups.single), {
      'a': 2222,
      'b': -2222,
    });
    final id = data.friends.single.id;
    expect(data.groups.single.member('b').friendId, id);
    expect(data.friends.single.lastFour, '6789');
    expect(data.bankApp?.id, 'app:example');
    expect(data.bankApp?.label, '測試 App');
    expect(await repo.readFriendAccount(id), fixtureNumber);
    final db = await databaseFactoryFfi.openDatabase(location);
    expect(await db.getVersion(), ledgerSchemaVersion);
    final stored =
        (await db.query('friends')).single['account_cipher'] as Uint8List;
    expect(stored.length, greaterThan(fixtureNumber.length));
    expect(
      latin1.decode(await File(location).readAsBytes()),
      isNot(contains(fixtureNumber)),
    );
    await repo.setFriendAccount(id, '007', fixtureNumber);
    final again =
        (await db.query('friends')).single['account_cipher'] as Uint8List;
    expect(again, isNot(orderedEquals(stored)));
    final damaged = Uint8List.fromList(again)..[0] ^= 1;
    await db.update(
      'friends',
      {'account_cipher': damaged},
      where: 'id = ?',
      whereArgs: [id],
    );
    await expectLater(repo.readFriendAccount(id), throwsFormatException);
    await repo.setBankApp(null);
    expect((await repo.load()).bankApp, isNull);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });
}
