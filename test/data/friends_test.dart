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
    expect(await db.getVersion(), 2);
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
