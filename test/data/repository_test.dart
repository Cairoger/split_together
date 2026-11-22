import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:split_together/data/memory_repository.dart';
import 'package:split_together/data/repository.dart';
import 'package:split_together/data/schema.dart';
import 'package:split_together/data/sqlite_repository.dart';
import 'package:split_together/domain.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _date = DateTime.utc(2026, 5, 20, 10, 30);

class _FailFirstOpen extends Fake implements DatabaseFactory {
  bool _failed = false;

  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) {
    if (!_failed) {
      _failed = true;
      throw StateError('資料庫暫時無法開啟');
    }
    return databaseFactoryFfi.openDatabase(path, options: options);
  }
}

Expense _expense(String id, String payer, String participant, int amount) =>
    Expense(
      id: id,
      title: '車票',
      amount: amount,
      payerId: payer,
      method: SplitMethod.weight,
      category: '交通',
      spentAt: _date.toLocal(),
      note: '來回',
      createdAt: _date,
      updatedAt: _date,
      shares: {participant: amount},
      inputs: {participant: 3},
    );

Repayment _repayment(String id, String from, String to, int amount) =>
    Repayment(
      id: id,
      fromId: from,
      toId: to,
      amount: amount,
      paidAt: _date.toLocal(),
      note: '部分還款',
      createdAt: _date,
    );

void main() {
  sqfliteFfiInit();
  test('資料庫開啟失敗後可重試', () async {
    final repo = SqliteSplitRepository(factory: _FailFirstOpen(), path: inMemoryDatabasePath);
    addTearDown(repo.close);
    await expectLater(repo.load(), throwsStateError);
    expect((await repo.load()).groups, isEmpty);
  });
  for (final useSqlite in [false, true]) {
    group(useSqlite ? 'SQLite' : '記憶體', () {
      late SplitRepository repo;
      late String id;
      late String self;
      late String guest;
      setUp(() async {
        repo = useSqlite
            ? SqliteSplitRepository(
                factory: databaseFactoryFfi,
                path: inMemoryDatabasePath,
              )
            : MemorySplitRepository();
        expect((await repo.load()).groups, isEmpty);
        await repo.setDefaultName(' 記帳人 ');
        id = await repo.createGroup(' 旅行 ', '旅遊', ['朋友']);
        final group = (await repo.load()).groups.single;
        self = group.self.id;
        guest = group.members.singleWhere((m) => !m.isSelf).id;
      });
      tearDown(() => repo.close());

      test('切換外觀後保留群組、餘額與預設名稱', () async {
        await repo.saveExpense(id, _expense('e', self, guest, 3000));
        await repo.addRepayment(id, _repayment('r', guest, self, 1000));
        expect((await repo.load()).appearance, AppAppearance.light);

        for (final appearance in [AppAppearance.dark, AppAppearance.light]) {
          await repo.setAppearance(appearance);
          final data = await repo.load();
          expect(data.appearance, appearance);
          expect(data.defaultName, '記帳人');
          final group = data.groups.single;
          expect(group.id, id);
          expect(group.expenses.single.id, 'e');
          expect(group.repayments.single.id, 'r');
          expect(BalanceService.balances(group)[self], 2000);
        }
      });

      test('群組消費與收到還款只影響群組餘額，已記入的聚餐支出維持原份額', () async {
        final meal = QuickMeal(
          id: 'dinner',
          createdAt: _date,
          total: 60000,
          payerId: quickMealSelfId,
          people: {quickMealSelfId: '我', quickMealGuestId('dinner', 1): '小林'},
        );
        await repo.saveQuickMeal(meal);
        await repo.saveExpense(id, _expense('e', self, guest, 3000));
        final before = (await repo.load()).personalExpenses(_date);
        expect(before.meals, isEmpty);
        expect(before.monthTotal, 0);

        await repo.setQuickMealPersonalExpense(meal.id, true);
        await repo.addRepayment(id, _repayment('r', guest, self, 1000));
        final data = await repo.load();
        expect(BalanceService.balances(data.groups.single)[self], 2000);
        final after = data.personalExpenses(_date);
        expect(after.meals.single.id, meal.id);
        expect(after.monthTotal, 30000);
      });

      test('T01 建立、編輯成員及群組，拒絕空白與重名', () async {
        final group = (await repo.load()).groups.single;
        expect(group.self.name, '記帳人');
        expect(group.name, '旅行');
        await repo.renameMember(id, guest, ' 同學 ');
        await repo.addMember(id, '家人');
        await repo.editGroup(id, '晚餐', '聚餐');
        await expectLater(repo.addMember(id, ' 同學 '), throwsFormatException);
        await expectLater(
          repo.renameMember(id, self, '同學'),
          throwsFormatException,
        );
        await expectLater(repo.setDefaultName(' '), throwsFormatException);
        await expectLater(
          repo.deactivateMember(id, self),
          throwsFormatException,
        );
        await expectLater(
          repo.createGroup('無效', '其他', ['記帳人']),
          throwsFormatException,
        );
        await expectLater(
          repo.createGroup(' ', '其他', []),
          throwsFormatException,
        );
        final result = (await repo.load()).groups.single;
        expect(result.name, '晚餐');
        expect(result.category, '聚餐');
        expect(result.member(guest).name, '同學');
        expect(result.members.length, 3);
        expect(result.members.where((m) => m.isSelf && m.isActive).length, 1);
      });

      test('T07 部分還款、重送及同時提交按最新餘額驗證', () async {
        await repo.saveExpense(id, _expense('e', self, guest, 10000));
        final partial = _repayment('r', guest, self, 2500);
        await repo.addRepayment(id, partial);
        await expectLater(
          repo.addRepayment(id, partial),
          throwsFormatException,
        );
        await expectLater(
          repo.addRepayment(id, _repayment('over', guest, self, 7501)),
          throwsFormatException,
        );
        await expectLater(
          repo.addRepayment(id, _repayment('reverse', self, guest, 1)),
          throwsFormatException,
        );
        await expectLater(
          repo.addRepayment(id, _repayment('same', guest, guest, 1)),
          throwsFormatException,
        );
        expect(
          BalanceService.balances((await repo.load()).groups.single)[self],
          7500,
        );
        final concurrent = await Future.wait([
          for (final rid in ['one', 'two'])
            repo
                .addRepayment(id, _repayment(rid, guest, self, 6000))
                .then(
                  (_) => true,
                  onError: (Object e) {
                    expect(e, isA<FormatException>());
                    return false;
                  },
                ),
        ]);
        expect(concurrent.where((ok) => ok).length, 1);
        expect(
          BalanceService.balances((await repo.load()).groups.single)[self],
          1500,
        );
        await repo.deleteRepayment(id, 'r');
        expect(
          BalanceService.balances((await repo.load()).groups.single)[self],
          4000,
        );
      });

      test('T08 封存、停用與歷史編輯後的結算', () async {
        await repo.saveExpense(id, _expense('e', self, guest, 2000));
        await repo.saveExpense(id, _expense('e', self, guest, 2000));
        expect((await repo.load()).groups.single.expenses.length, 1);
        await expectLater(repo.setArchived(id, true), throwsFormatException);
        await expectLater(
          repo.deactivateMember(id, guest),
          throwsFormatException,
        );
        await repo.addRepayment(id, _repayment('r', guest, self, 2000));
        await repo.deactivateMember(id, guest);
        await expectLater(
          repo.saveExpense(id, _expense('new', self, guest, 5)),
          throwsFormatException,
        );
        await repo.setArchived(id, true);
        await expectLater(repo.deleteExpense(id, 'e'), throwsFormatException);
        await expectLater(repo.deleteRepayment(id, 'r'), throwsFormatException);
        await expectLater(
          repo.renameMember(id, guest, '新名字'),
          throwsFormatException,
        );
        await repo.setArchived(id, false);
        await repo.saveExpense(id, _expense('e', self, guest, 3000));
        final edited = (await repo.load()).groups.single;
        expect(edited.totalExpense, 3000);
        expect(edited.member(guest).isActive, isFalse);
        expect(BalanceService.balances(edited)[guest], -1000);
        await repo.addRepayment(id, _repayment('r2', guest, self, 1000));
        await repo.deleteExpense(id, 'e');
        final afterDelete = (await repo.load()).groups.single;
        expect(afterDelete.totalExpense, 0);
        expect(afterDelete.repayments.length, 2);
        expect(BalanceService.balances(afterDelete)[guest], 3000);
      });

      test('T09 群組隔離，總覽分別加總本人應收應付', () async {
        final id2 = await repo.createGroup('聚會', '聚餐', ['朋友']);
        final second = (await repo.load()).groups.singleWhere(
          (g) => g.id == id2,
        );
        final self2 = second.self.id;
        final guest2 = second.members.singleWhere((m) => !m.isSelf).id;
        await repo.saveExpense(id, _expense('first', self, guest, 1000));
        await expectLater(
          repo.saveExpense(id, _expense('foreign-payer', self2, guest, 1)),
          throwsFormatException,
        );
        await expectLater(
          repo.saveExpense(id, _expense('foreign-split', self, guest2, 1)),
          throwsFormatException,
        );
        await expectLater(
          repo.addRepayment(id, _repayment('r', guest2, self, 1)),
          throwsFormatException,
        );
        await repo.saveExpense(id2, _expense('second', guest2, self2, 700));
        expect(BalanceService.overview((await repo.load()).groups), (
          receivable: 1000,
          payable: 700,
          net: 300,
        ));
        await expectLater(
          repo.deleteExpense(id, 'second'),
          throwsFormatException,
        );
        await repo.deleteExpense(id, 'first');
        expect(BalanceService.overview((await repo.load()).groups).net, -700);
      });
    });
  }

  group('SQLite 檔案與交易', () {
    late Directory directory;
    late String path;
    late SqliteSplitRepository repo;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('split_ledger_test_');
      path = p.join(directory.path, 'test.db');
      repo = SqliteSplitRepository(factory: databaseFactoryFfi, path: path);
    });
    tearDown(() async {
      await repo.close();
      await directory.delete(recursive: true);
    });

    test('T10 關閉及重新開啟檔案保留設定、歷史、日期與分攤輸入', () async {
      await repo.setAppearance(AppAppearance.dark);
      await repo.setDefaultName('甲');
      final id = await repo.createGroup('生活', '生活', ['乙']);
      final original = (await repo.load()).groups.single;
      final guest = original.members.singleWhere((m) => !m.isSelf).id;
      await repo.saveExpense(id, _expense('車票', original.self.id, guest, 4200));
      await repo.addRepayment(
        id,
        _repayment('已付', guest, original.self.id, 1200),
      );
      await repo.close();
      repo = SqliteSplitRepository(factory: databaseFactoryFfi, path: path);
      final loaded = await repo.load();
      final restored = loaded.groups.single;
      expect(loaded.defaultName, '甲');
      expect(loaded.appearance, AppAppearance.dark);
      expect(restored.id, original.id);
      expect(restored.self.id, original.self.id);
      expect(restored.expenses.single.spentAt, _date);
      expect(restored.expenses.single.spentAt.isUtc, isTrue);
      expect(restored.expenses.single.note, '來回');
      expect(restored.expenses.single.shares, {guest: 4200});
      expect(restored.expenses.single.inputs, {guest: 3});
      expect(restored.expenses.single.method, SplitMethod.weight);
      expect(restored.repayments.single.id, '已付');
      expect(restored.repayments.single.paidAt, _date);
      expect(BalanceService.balances(restored)[guest], -3000);
    });

    test('舊帳本沒有外觀設定或設定值不明時採用光亮模式', () async {
      final id = await repo.createGroup('舊帳本', '生活', []);
      final db = await databaseFactoryFfi.openDatabase(path);
      expect(await db.getVersion(), ledgerSchemaVersion);
      expect((await repo.load()).appearance, AppAppearance.light);
      await db.insert('app_settings', {'key': 'appearance', 'value': 'other'});
      await repo.close();

      repo = SqliteSplitRepository(factory: databaseFactoryFfi, path: path);
      final restored = await repo.load();
      expect(restored.appearance, AppAppearance.light);
      expect(restored.groups.single.id, id);
      await repo.setAppearance(AppAppearance.dark);
      expect((await repo.load()).appearance, AppAppearance.dark);
    });

    test('資料庫外鍵阻擋錯誤成員，更新分攤途中出錯會回滾所有異動', () async {
      final id = await repo.createGroup('測試', '其他', ['乙']);
      final group = (await repo.load()).groups.single;
      final guest = group.members.singleWhere((m) => !m.isSelf).id;
      await repo.saveExpense(id, _expense('e', group.self.id, guest, 200));
      // sqflite reuses this single instance, with the repository configuration.
      final db = await databaseFactoryFfi.openDatabase(path);
      expect(
        (await db.rawQuery('PRAGMA foreign_keys')).single.values.single,
        1,
      );
      expect(await db.getVersion(), ledgerSchemaVersion);
      await expectLater(
        db.update(
          'expenses',
          {'payer_member_id': 'missing'},
          where: 'id = ?',
          whereArgs: ['e'],
        ),
        throwsA(isA<DatabaseException>()),
      );
      await db.execute(
        """CREATE TRIGGER reject_split BEFORE INSERT ON expense_splits
          WHEN NEW.amount_minor = 300 BEGIN SELECT RAISE(ABORT, 'test split rollback'); END""",
      );
      await expectLater(
        repo.saveExpense(id, _expense('e', group.self.id, guest, 300)),
        throwsA(isA<DatabaseException>()),
      );
      final after = (await repo.load()).groups.single;
      expect(after.expenses.single.amount, 200);
      expect(after.expenses.single.shares, {guest: 200});
      await repo.deleteExpense(id, 'e');
      expect(await db.query('expense_splits'), isEmpty);
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    });
  });
}
