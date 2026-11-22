import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:split_together/data/account_cipher.dart';
import 'package:split_together/data/ledger_backup.dart';
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/data/repository.dart';
import 'package:split_together/data/schema.dart';
import 'package:split_together/data/sqlite_repository.dart';
import 'package:split_together/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _date = DateTime.utc(2026, 9, 3, 8, 15, 0, 3, 17);
const _testAccount = '00000043216789';

// 由 v1 匯出程式產生，固定舊檔的欄位與原始摘要。
const _legacyBackup =
    '{"format":"SplitTogether-Ledger","version":1,"createdAt":"2026-06-01T00:00:00.000Z",'
    '"data":{"currency":"TWD","friends":[],"groups":[],"quickMeals":[{"id":"old",'
    '"createdAt":"2026-05-31T13:00:00.000Z","totalMinor":601,"payerId":"@guest:old:1",'
    '"people":{"@self":"我","@guest:old:1":"小林"},"shares":{"@self":301,"@guest:old:1":300}}]},'
    '"sha256":"e6d0a465f2f34bdcd8d8ceeefddfd27a356d23d2b6e9b7d1a7882b04e4fc1709"}';

Future<void> _populate(SplitRepository repo) async {
  await repo.setBankApp(const BankAppChoice(id: 'test.source', label: '測試轉帳'));
  await repo.setDefaultName('出遊時的我');
  final friend = await repo.createFriend('小方');
  await repo.setFriendAccount(friend, '700', _testAccount);
  final group = await repo.createGroupWithMembers('測試旅行', '旅遊', [
    MemberDraft(name: '小方', friendId: friend),
    const MemberDraft(name: '小林'),
  ]);
  final members = (await repo.load()).groups.single.members;
  final self = members.singleWhere((m) => m.isSelf).id;
  final guest = members.singleWhere((m) => m.friendId == friend).id;
  final inputs = {self: 3333, guest: 6667};
  const amount = 100001;
  await repo.saveExpense(
    group,
    Expense(
      id: 'ticket',
      title: '客運車票',
      amount: amount,
      payerId: self,
      method: SplitMethod.percent,
      category: '交通',
      spentAt: _date,
      note: '虛構的測試行程',
      createdAt: _date,
      updatedAt: _date,
      shares: SplitService.divide(
        amount,
        SplitMethod.percent,
        inputs.keys.toList(),
        inputs,
      ),
      inputs: inputs,
    ),
  );
  await repo.addRepayment(
    group,
    Repayment(
      id: 'partial',
      fromId: guest,
      toId: self,
      amount: 20001,
      paidAt: _date,
      createdAt: _date,
      note: '先付一部分',
    ),
  );
  await repo.deactivateMember(
    group,
    members.singleWhere((m) => m.name == '小林').id,
  );
  final closed = await repo.createGroup('封存測試', '其他', []);
  await repo.setArchived(closed, true);
  await repo.saveQuickMeal(
    QuickMeal.recorded(
      id: 'dinner',
      createdAt: _date,
      total: 100000,
      payerId: friend,
      people: {
        quickMealSelfId: '當時的我',
        friend: '當時的小方',
        quickMealGuestId('dinner', 1): '臨時成員',
      },
      shares: {
        quickMealSelfId: 33334,
        friend: 33333,
        quickMealGuestId('dinner', 1): 33333,
      },
    ),
  );
  await repo.renameFriend(friend, '改名的小方');
  await repo.archiveFriend(friend);
}

Future<SqliteSplitRepository> _sqlite(String path) async {
  final key = await AesGcm.with256bits().newSecretKey();
  final repo = SqliteSplitRepository(
    factory: databaseFactoryFfi,
    path: path,
    accountCipher: AccountCipher(loadKey: (_) async => key),
  );
  addTearDown(repo.close);
  return repo;
}

Future<Directory> _temp() async {
  final dir = await Directory.systemTemp.createTemp('split-backup-test-');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

void main() {
  sqfliteFfiInit();
  for (final sqlite in [false, true]) {
    final label = sqlite ? 'SQLite' : '記憶體';
    group(label, () {
      late SplitRepository source, target;
      setUp(() async {
        if (sqlite) {
          final dir = await _temp();
          source = await _sqlite(p.join(dir.path, 'source.db'));
          target = await _sqlite(p.join(dir.path, 'target.db'));
        } else {
          source = MemorySplitRepository();
          target = MemorySplitRepository();
        }
      });

      test('看過範例結果的狀態會保留在本機，教學設定不會寫入帳本備份', () async {
        final before = await (await source.createBackup(_date)).encode();
        expect((await source.load()).hasSeenExampleResult, isFalse);
        await source.markExampleResultSeen();
        await source.close();
        expect((await source.load()).hasSeenExampleResult, isTrue);
        expect(await source.isLedgerEmpty(), isTrue);
        final after = await (await source.createBackup(_date)).encode();
        expect(after, orderedEquals(before));
        await target.restoreBackup(await LedgerBackup.decode(after));
        expect((await target.load()).hasSeenExampleResult, isFalse);
      });

      test('匯出後還原保留歷史、分攤與還款，只保留目的裝置的設定', () async {
        await _populate(source);
        final before = await source.load();
        final bytes = await (await source.createBackup(_date)).encode();
        final exported = utf8.decode(bytes);
        expect(exported, isNot(contains(_testAccount)));
        expect(exported, isNot(contains('test.source')));

        final backup = await LedgerBackup.decode(bytes);
        await target.setAppearance(AppAppearance.dark);
        await target.markExampleResultSeen();
        await target.setDefaultName('新手機');
        await target.setBankApp(
          const BankAppChoice(id: 'test.target', label: '本機選項'),
        );
        expect(await target.isLedgerEmpty(), isTrue);
        await target.restoreBackup(backup);
        await target.close();

        final after = await target.load();
        expect(after.defaultName, '新手機');
        expect(after.appearance, AppAppearance.dark);
        expect(after.hasSeenExampleResult, isTrue);
        expect(after.bankApp?.id, 'test.target');
        expect(after.friends.single.id, before.friends.single.id);
        expect(after.friends.single.isArchived, isTrue);
        expect(after.friends.single.name, '改名的小方');
        expect(after.friends.single.lastFour, isNull);
        expect(after.friends.single.bankCode, isNull);
        expect(await target.readFriendAccount(after.friends.single.id), isNull);
        expect(
          await source.readFriendAccount(after.friends.single.id),
          _testAccount,
        );
        expect(after.groups.singleWhere((g) => g.archived).name, '封存測試');
        final old = before.groups.singleWhere((g) => !g.archived);
        final restored = after.groups.singleWhere((g) => !g.archived);
        expect(restored.createdAt, old.createdAt);
        expect(restored.updatedAt, old.updatedAt);
        expect(restored.members.singleWhere((m) => !m.isActive).name, '小林');
        expect(
          restored.members.singleWhere((m) => m.friendId != null).friendId,
          after.friends.single.id,
        );
        expect(restored.expenses.single.inputs, old.expenses.single.inputs);
        expect(restored.expenses.single.shares, old.expenses.single.shares);
        expect(restored.expenses.single.spentAt, _date);
        expect(restored.repayments.single.id, 'partial');
        expect(restored.repayments.single.amount, 20001);
        expect(restored.repayments.single.paidAt, _date);
        expect(BalanceService.balances(restored), BalanceService.balances(old));
        final expected = SettlementService.suggest(BalanceService.balances(old))
            .single;
        final actual = SettlementService.suggest(
          BalanceService.balances(restored),
        ).single;
        expect(
          (actual.fromId, actual.toId, actual.amount),
          (expected.fromId, expected.toId, expected.amount),
        );
        after.quickMeals.single.verifyRetry(before.quickMeals.single);
        expect(
          after.quickMeals.single.shareText,
          before.quickMeals.single.shareText,
        );
        expect(await target.isLedgerEmpty(), isFalse);
      });

      test('v1 舊餐預設未記帳，記入後 v2 備份往返保留各餐狀態與原分攤', () async {
        final legacy = await LedgerBackup.decode(utf8.encode(_legacyBackup));
        await source.restoreBackup(legacy);
        final old = (await source.load()).quickMeals.single;
        expect(old.id, 'old');
        expect(old.createdAt, DateTime.utc(2026, 5, 31, 13));
        expect(old.recordedAsPersonalExpense, isFalse);
        expect(old.selfShare, 301);
        await source.setQuickMealPersonalExpense(old.id, true);
        await source.saveQuickMeal(
          QuickMeal(
            id: 'new',
            createdAt: _date,
            total: 200,
            payerId: quickMealSelfId,
            people: {quickMealSelfId: '我', quickMealGuestId('new', 1): '朋友'},
          ),
        );
        final bytes = await (await source.createBackup(_date)).encode();
        final restored = await LedgerBackup.decode(bytes);
        await target.restoreBackup(restored);
        await target.close();

        final meals = (await target.load()).quickMeals;
        expect(
          {
            for (final m in meals)
              m.id: (m.recordedAsPersonalExpense, m.selfShare),
          },
          {'old': (true, 301), 'new': (false, 100)},
        );
        final restoredOld = meals.singleWhere((m) => m.id == 'old');
        old.verifyRetry(restoredOld);
        expect(restoredOld.shareText, old.shareText);
        await expectLater(target.restoreBackup(legacy), throwsFormatException);
      });

      for (final kind in ['封存朋友', '空群組', '只有聚餐']) {
        test('確認後出現$kind，再次檢查會停止匯入', () async {
          await source.createFriend('備份朋友');
          final backup = await source.createBackup(_date);
          expect(await target.isLedgerEmpty(), isTrue);
          switch (kind) {
            case '封存朋友':
              final id = await target.createFriend('本機朋友');
              await target.archiveFriend(id);
            case '空群組':
              final id = await target.createGroup('本機群組', '其他', []);
              await target.setArchived(id, true);
            case '只有聚餐':
              await target.saveQuickMeal(
                QuickMeal(
                  id: 'local',
                  createdAt: _date,
                  total: 99,
                  payerId: quickMealSelfId,
                  people: {
                    quickMealSelfId: '我',
                    quickMealGuestId('local', 1): '友',
                  },
                ),
              );
          }
          expect(await target.isLedgerEmpty(), isFalse);
          await expectLater(
            target.restoreBackup(backup),
            throwsFormatException,
          );
          final current = await target.load();
          expect(current.friends.where((f) => f.name == '備份朋友'), isEmpty);
          expect(
            current.friends.length +
                current.groups.length +
                current.quickMeals.length,
            1,
          );
        });
      }

      test('連續兩筆還原只有一筆可寫入', () async {
        await source.createFriend('只出現一次');
        final backup = await source.createBackup(_date);
        final results = await Future.wait([
          for (var i = 0; i < 2; i++)
            target
                .restoreBackup(backup)
                .then(
                  (_) => true,
                  onError: (Object e) {
                    expect(e, isA<FormatException>());
                    return false;
                  },
                ),
        ]);
        expect(results.where((ok) => ok), hasLength(1));
        expect((await target.load()).friends, hasLength(1));
      });
    });
  }

  test('重開目前版本的帳本，可直接匯出並保留本機銀行資料', () async {
    final path = p.join((await _temp()).path, 'split_together.db');
    final key = await AesGcm.with256bits().newSecretKey();
    SqliteSplitRepository openLedger() => SqliteSplitRepository(
      path: path,
      factory: databaseFactoryFfi,
      accountCipher: AccountCipher(loadKey: (_) async => key),
    );

    final original = openLedger();
    addTearDown(original.close);
    await _populate(original);
    final before = await original.load();
    final existingDb = await databaseFactoryFfi.openDatabase(path);
    expect(await existingDb.getVersion(), ledgerSchemaVersion);
    await original.close();

    final reopened = openLedger();
    addTearDown(reopened.close);
    final snapshot = await reopened.createBackup(_date);
    final expected = LedgerBackup.fromData(before, _date);
    expect(await snapshot.encode(), orderedEquals(await expected.encode()));
    final data = await reopened.load();
    expect(data.defaultName, before.defaultName);
    expect(data.bankApp?.id, before.bankApp?.id);
    expect(data.friends.single.lastFour, before.friends.single.lastFour);
    expect(
      await reopened.readFriendAccount(data.friends.single.id),
      _testAccount,
    );
  });

  test('還原最後一筆參與者時失敗，SQLite 交易連先前寫入的帳目也回滾，之後可重試', () async {
    final source = MemorySplitRepository();
    await _populate(source);
    final backup = await source.createBackup(_date);
    final target = await _sqlite(p.join((await _temp()).path, 'rollback.db'));
    await target.setDefaultName('保留我的設定');
    final db = await databaseFactoryFfi.openDatabase(target.path!);
    await db.execute("""
      CREATE TRIGGER fail_restore BEFORE INSERT ON quick_meal_people
      BEGIN SELECT RAISE(ABORT, '測試交易回滾'); END
    """);
    await expectLater(
      target.restoreBackup(backup),
      throwsA(isA<DatabaseException>()),
    );
    expect(await target.isLedgerEmpty(), isTrue);
    for (final table in [
      'groups',
      'members',
      'expenses',
      'expense_splits',
      'settlements',
      'friends',
      'quick_meals',
      'quick_meal_people',
    ]) {
      expect(await db.query(table), isEmpty, reason: table);
    }
    expect((await target.load()).defaultName, '保留我的設定');
    await db.execute('DROP TRIGGER fail_restore');
    await target.restoreBackup(backup);
    expect((await target.load()).quickMeals, hasLength(1));
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });
}
